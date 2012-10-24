require 'rubygems'

# See also README.markdown for documentation
module Workflow
  autoload :ActiveModelPersistence, 'workflow/active_model_persistence'
  autoload :MongoidPersistence,     'workflow/mongoid_persistence'
  autoload :RemodelPersistence,     'workflow/remodel_persistence'
  autoload :Transactional,          'workflow/transactional'

  class Specification

    attr_accessor :states, :initial_state, :meta, :on_transition_proc, :on_failed_transition_proc

    def initialize(meta = {}, &specification)
      @states = Hash.new
      @meta = meta
      instance_eval(&specification)
    end

    def state_names
      states.keys
    end

    private

    def state(name, meta = {:meta => {}}, &events_and_etc)
      # meta[:meta] to keep the API consistent..., gah
      new_state = Workflow::State.new(name, meta[:meta])
      @initial_state       = new_state if @states.empty?
      @states[name.to_sym] = new_state
      @scoped_state        = new_state
      instance_eval(&events_and_etc) if events_and_etc
    end

    def event(name, args = {}, &action)
      target = args[:transitions_to] || args[:transition_to]
      if target.nil?
        raise WorkflowDefinitionError.new \
          "missing ':transitions_to' in workflow event definition for '#{name}'"
      end
      @scoped_state.events[name.to_sym] =
        Workflow::Event.new(name, target, (args[:meta] || {}), &action)
    end

    def allow(name, args={}, &action)
      args[:transitions_to] ||= args[:transition_to] || @scoped_state.to_sym
      event name, args, &action
    end

    def on_entry(&proc_to_run)
      @scoped_state.on_entry = proc_to_run
    end

    def on_exit(&proc_to_run)
      @scoped_state.on_exit = proc_to_run
    end

    def on_transition(&proc_to_run)
      @on_transition_proc = proc_to_run
    end

    def on_failed_transition(&proc_to_run)
      @on_failed_transition_proc = proc_to_run
    end
  end

  class TransitionHalted < Exception

    attr_reader :halted_because

    def initialize(msg = nil)
      @halted_because = msg
      super msg
    end

  end

  class NoTransitionAllowed < Exception; end

  class WorkflowError < Exception; end

  class WorkflowDefinitionError < Exception; end

  class State

    attr_accessor :name, :events, :meta, :on_entry, :on_exit

    def initialize(name, meta = {})
      @name, @events, @meta = name, Hash.new, meta
    end

    def to_s
      "#{name}"
    end

    def to_sym
      name.to_sym
    end
  end

  class Event

    attr_accessor :name, :transitions_to, :meta, :action

    def initialize(name, transitions_to, meta = {}, &action)
      @name, @transitions_to, @meta, @action = name, transitions_to.to_sym, meta, action
    end

    def perform_validation?
      !self.meta[:skip_all_validations]
    end

  end

  module WorkflowClassMethods
    attr_reader :workflow_spec

    def workflow_column(column_name=nil)
      if column_name
        @workflow_state_column_name = column_name.to_sym
      end
      if !@workflow_state_column_name && superclass.respond_to?(:workflow_column)
        @workflow_state_column_name = superclass.workflow_column
      end
      @workflow_state_column_name ||= :workflow_state
    end

    def workflow(&specification)
      @workflow_spec = Specification.new(Hash.new, &specification)
      @workflow_spec.states.values.each do |state|
        state_name = state.name
        module_eval do
          define_method "#{state_name}?" do
            state_name.to_sym == current_state.name.to_sym
          end

          define_method "in_#{state_name}_exit?" do
            return self.in_exit.to_sym == state_name.to_sym
          end

          define_method "in_#{state_name}_entry?" do
            return self.in_entry.to_sym == state_name.to_sym
          end
        end

        state.events.values.each do |event|
          event_name = event.name
          module_eval do
            define_method "#{event_name}!".to_sym do |*args|
              process_event!(event_name, *args)
            end

            # this allows checks like can_approve? or can_reject_item?
            # note we don't have a more generic can?(:approve) method.
            # this is fully intentional, since this way it is far easier
            # to overwrite the can_...? mehtods in a model than it would be
            # with a generic can?(...) method.
            define_method "can_#{event_name}?" do
              return self.current_state.events.include? event_name
            end

            define_method "in_transition_#{event_name}?" do
              return self.in_transition.to_sym == event_name.to_sym
            end
          end
        end
      end
    end
  end

  module WorkflowInstanceMethods
    attr_accessor :in_entry, :in_exit, :in_transition

    def current_state
      loaded_state = load_workflow_state
      res = spec.states[loaded_state.to_sym] if loaded_state
      res || spec.initial_state
    end

    # See the 'Guards' section in the README
    # @return true if the last transition was halted by one of the transition callbacks.
    def halted?
      @halted
    end

    # @return the reason of the last transition abort as set by the previous
    # call of `halt` or `halt!` method.
    def halted_because
      @halted_because
    end

    def process_event!(name, *args)
      assure_transition_allowed! name
      event = current_state.events[name.to_sym]
      assure_target_state_exists!(event)
      set_transition_flags(current_state, spec.states[event.transitions_to], event)
      @halted_because = nil
      @halted         = false
      return_value    = run_action(event.action, *args) || run_action_callback(event.name, *args)
      if @halted
        run_on_failed_transition(*args)
        return_value = false
      else
        if event.perform_validation? and not valid?
          run_on_failed_transition(*args)
          @halted = true # make sure this one is not reset in the on_failed_transition callback
          return_value = false
        else
          transition(*args)
        end
      end
      return_value.nil? ? true : return_value
    end

    def set_transition_flags(current_state, target_state, event)
      @in_exit       = current_state
      @in_entry      = target_state
      @in_transition = event
    end

    def clear_transition_flags
      set_transition_flags nil, nil, nil
    end

    def halt(reason = nil)
      @halted_because = reason
      @halted = true
    end

    def halt!(reason = nil)
      halt reason
      raise TransitionHalted.new(reason)
    end

    def spec
      # check the singleton class first
      class << self
        return workflow_spec if workflow_spec
      end

      c = self.class
      # using a simple loop instead of class_inheritable_accessor to avoid
      # dependency on Rails' ActiveSupport
      until c.workflow_spec || !(c.include? Workflow)
        c = c.superclass
      end
      c.workflow_spec
    end

    protected

    def assure_transition_allowed!(name)
      unless self.send "can_#{name}?"
        prohibit_transition! name
      end
    end

    def prohibit_transition!(name)
      raise NoTransitionAllowed.new \
          "There is no event #{name} defined for the #{current_state} state."
    end

    def assure_target_state_exists!(event)
      # Create a meaningful error message instead of
      # "undefined method `on_entry' for nil:NilClass"
      # Reported by Kyle Burton
      if !spec.states[event.transitions_to]
        raise WorkflowError.new \
            "Event[#{event.name}]'s transitions_to[#{event.transitions_to}] is not a declared state."
      end
    end

    def transition(*args)
      run_on_exit(*args)
      run_on_transition(*args)
      val = persist_workflow_state wf_target_state.name
      run_on_entry(*args)
      val
    end

    def run_on_transition(*args)
      instance_exec(self.wf_prior_state.name, self.wf_target_state.name, self.wf_event_name, *args, &spec.on_transition_proc) if spec.on_transition_proc
    end

    def run_on_failed_transition(*args)
      if spec.on_failed_transition_proc
        return_value = instance_exec(self.wf_prior_state.name, self.wf_target_state.name, self.wf_event_name, *args, &spec.on_failed_transition_proc)
      else
        return_value = halt(:validation_failed)
      end
      clear_transition_flags
      return return_value
    end

    def run_action(action, *args)
      instance_exec(*args, &action) if action
    end

    def run_action_callback(action_name, *args)
      self.send action_name.to_sym, *args if self.respond_to?(action_name.to_sym)
    end

    def run_on_entry(*args)
      if self.wf_target_state.on_entry
        instance_exec(self.wf_prior_state.name, self.wf_event_name, *args, &self.wf_target_state.on_entry)
      else
        hook_name = "on_#{self.wf_target_state.name}_entry"
        self.send hook_name, self.wf_prior_state, self.wf_event_name, *args if self.respond_to? hook_name
      end
    end

    def run_on_exit(*args)
      if self.wf_prior_state # no on_exit for entry into initial state
        if self.wf_prior_state.on_exit
          instance_exec(self.wf_target_state.name, self.wf_event_name, *args, &self.wf_prior_state.on_exit)
        else
          hook_name = "on_#{self.wf_prior_state.name}_exit"
          self.send hook_name, self.wf_target_state, self.wf_event_name, *args if self.respond_to? hook_name
        end
      end
    end

    def wf_prior_state
      @in_exit
    end

    def wf_target_state
      @in_entry
    end

    def wf_event_name
      @in_transition.name
    end

    def wf_event
      @in_transition
    end

    # load_workflow_state and persist_workflow_state
    # can be overriden to handle the persistence of the workflow state.
    #
    # Default (non ActiveRecord) implementation stores the current state
    # in a variable.
    #
    # Default ActiveRecord implementation uses a 'workflow_state' database column.
    def load_workflow_state
      @workflow_state if instance_variable_defined? :@workflow_state
    end

    def persist_workflow_state(new_value)
      @workflow_state = new_value
    end
  end

  def self.included(klass)
    klass.send :include, WorkflowInstanceMethods
    klass.extend WorkflowClassMethods

#     [ActiveModelPersistence, MongoidPersistence, RemodelPersistence].each do |konst|
#       if konst.happy_to_be_included_in? klass
#       raise "including #{konst}"
#         raise "including #{konst}"
#         klass.send :include, konst
#       end
#     end
  end

  # Generates a `dot` graph of the workflow.
  # Prerequisite: the `dot` binary. (Download from http://www.graphviz.org/)
  # You can use this method in your own Rakefile like this:
  #
  #     namespace :doc do
  #       desc "Generate a graph of the workflow."
  #       task :workflow => :environment do # needs access to the Rails environment
  #         Workflow::create_workflow_diagram(Order)
  #       end
  #     end
  #
  # You can influence the placement of nodes by specifying
  # additional meta information in your states and transition descriptions.
  # You can assign higher `doc_weight` value to the typical transitions
  # in your workflow. All other states and transitions will be arranged
  # around that main line. See also `weight` in the graphviz documentation.
  # Example:
  #
  #     state :new do
  #       event :approve, :transitions_to => :approved, :meta => {:doc_weight => 8}
  #     end
  #
  #
  # @param klass A class with the Workflow mixin, for which you wish the graphical workflow representation
  # @param [String] target_dir Directory, where to save the dot and the pdf files
  # @param [String] graph_options You can change graph orientation, size etc. See graphviz documentation
  def self.create_workflow_diagram(klass, target_dir='.', graph_options='rankdir="LR", size="7,11.6", ratio="fill"')
    workflow_name = "#{klass.name.tableize}_workflow".gsub('/', '_')
    fname = File.join(target_dir, "generated_#{workflow_name}")
    File.open("#{fname}.dot", 'w') do |file|
      file.puts klass.new.workflow_diagram(graph_options)
    end
    `dot -Tpdf -o'#{fname}.pdf' '#{fname}.dot'`
    puts "A PDF file was generated at '#{fname}.pdf'"
  end

  # Returns a representation of the state diagram for the
  # calling model as a string in dot language.
  # See Workflow.create_workflow_diagram for more deails
  def workflow_diagram(graph_options)
    str = <<-EOS
digraph #{self.class} {
  graph [#{graph_options}];
  node [shape=box];
  edge [len=1];
    EOS

    self.class.workflow_spec.states.each do |state_name, state|
      state_meta = state.meta
      if state == self.class.workflow_spec.initial_state
        str << %Q{  #{state.name} [label="#{state.name}", shape=circle];\n}
      else
        str << %Q{  #{state.name} [label="#{state.name}", shape=#{state_meta[:terminal] ? 'doublecircle' : 'box, style=rounded'}];\n}
      end
      state.events.each do |event_name, event|
        event_meta = event.meta
        event_meta[:doc_weight] = 6 if event_meta[:main_path]
        if event_meta[:doc_weight]
          weight_prop = ", weight=#{event_meta[:doc_weight]}, penwidth=#{event_meta[:doc_weight] / 2 || 0.0}\n"
        else
          weight_prop = ''
        end
        str << %Q{  #{state.name} -> #{event.transitions_to} [label="#{event_name.to_s.humanize}" #{weight_prop}];\n}
      end
    end
    str << "}\n"
    return str
  end
end
