require 'rubygems'

# See also README.markdown for documentation
module Workflow

  class Specification

    attr_accessor :states, :initial_state, :meta, :on_transition_proc

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
      @initial_state = new_state if @states.empty?
      @states[name.to_sym] = new_state
      @scoped_state = new_state
      instance_eval(&events_and_etc) if events_and_etc
    end

    def event(name, args = {}, &action)
      target = args[:transitions_to] || args[:transition_to]
      raise WorkflowDefinitionError.new(
        "missing ':transitions_to' in workflow event definition for '#{name}'") \
        if target.nil?
      @scoped_state.events[name.to_sym] =
        Workflow::Event.new(name, target, (args[:meta] or {}), &action)
    end

    def on_entry(&proc)
      @scoped_state.on_entry = proc
    end

    def on_exit(&proc)
      @scoped_state.on_exit = proc
    end

    def on_transition(&proc)
      @on_transition_proc = proc
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
      event = current_state.events[name.to_sym]
      if event.nil?
        raise NoTransitionAllowed.new \
            "There is no event #{name.to_sym} defined for the #{current_state} state"
      end
      target_state = spec.states[event.transitions_to]
      @halted_because = nil
      @halted         = false
      set_transition_flags(current_state, target_state, name)
      return_value = run_action(event.action, *args) || run_action_callback(event.name, *args)
      if @halted
        return false
      else
        check_transition(event)
        # TODO: shift this down by one line?!
        # ... or possibly validate twice!
        run_on_transition(current_state, target_state, name, *args) # if valid?
        if event.meta[:skip_all_validations] or valid?
          transition(current_state, target_state, name, *args)
        else
          @halted_because = 'Validation for transition failed: %{errors}' % {:errors => self.errors.full_messages.join(', ')}
          @halted = true
          return false
        end
        return_value.nil? ? true : return_value
      end
    end

    def set_transition_flags(current_state, target_state, event_name)
      self.in_exit       = current_state.to_s
      self.in_entry      = target_state.to_s
      self.in_transition = event_name.to_s
    end

    def halt(reason = nil)
      @halted_because = reason
      @halted = true
    end

    def halt!(reason = nil)
      @halted_because = reason
      @halted = true
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

    private

    def check_transition(event)
      # Create a meaningful error message instead of
      # "undefined method `on_entry' for nil:NilClass"
      # Reported by Kyle Burton
      if !spec.states[event.transitions_to]
        raise WorkflowError.new("Event[#{event.name}]'s " +
            "transitions_to[#{event.transitions_to}] is not a declared state.")
      end
    end

    def transition(from, to, name, *args)
      run_on_exit(from, to, name, *args)
      val = persist_workflow_state to.to_s
      run_on_entry(to, from, name, *args)
      val
    end

    def run_on_transition(from, to, event, *args)
      instance_exec(from.name, to.name, event, *args, &spec.on_transition_proc) if spec.on_transition_proc
    end

    def run_action(action, *args)
      instance_exec(*args, &action) if action
    end

    def run_action_callback(action_name, *args)
      self.send action_name.to_sym, *args if self.respond_to?(action_name.to_sym)
    end

    def run_on_entry(state, prior_state, triggering_event, *args)
      if state.on_entry
        instance_exec(prior_state.name, triggering_event, *args, &state.on_entry)
      else
        hook_name = "on_#{state}_entry"
        self.send hook_name, prior_state, triggering_event, *args if self.respond_to? hook_name
      end
    end

    def run_on_exit(state, new_state, triggering_event, *args)
      if state
        if state.on_exit
          instance_exec(new_state.name, triggering_event, *args, &state.on_exit)
        else
          hook_name = "on_#{state}_exit"
          self.send hook_name, new_state, triggering_event, *args if self.respond_to? hook_name
        end
      end
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

  module ActiveRecordInstanceMethods
    def load_workflow_state
      read_attribute(self.class.workflow_column)
    end

    # On transition the new workflow state is immediately saved in the
    # database.
    def persist_workflow_state(new_value)
      update_attribute self.class.workflow_column, new_value
    end

    private

    # Motivation: even if NULL is stored in the workflow_state database column,
    # the current_state is correctly recognized in the Ruby code. The problem
    # arises when you want to SELECT records filtering by the value of initial
    # state. That's why it is important to save the string with the name of the
    # initial state in all the new records.
    def write_initial_state
      write_attribute self.class.workflow_column, current_state.to_s
    end
  end

  module RemodelInstanceMethods
    def load_workflow_state
      send(self.class.workflow_column)
    end

    def persist_workflow_state(new_value)
      update(self.class.workflow_column => new_value)
    end
  end

  module MongoidInstanceMethods
    include ActiveRecordInstanceMethods
    # implementation of abstract method: saves new workflow state to DB
    def persist_workflow_state(new_value)
      self.write_attribute(self.class.workflow_column, new_value.to_s)
      self.save! :validate => false
    end
  end

  def self.included(klass)
    klass.send :include, WorkflowInstanceMethods
    klass.extend WorkflowClassMethods
    if Object.const_defined?(:ActiveRecord) and klass < ActiveRecord::Base
      klass.send :include, ActiveRecordInstanceMethods
      klass.before_validation :write_initial_state
    end

    if Object.const_defined?(:Remodel) and klass < Remodel::Entity
      klass.send :include, RemodelInstanceMethods
    end

    if Object.const_defined?(:Mongoid) and klass.include? Mongoid::Document
      klass.send :include, MongoidInstanceMethods
      klass.after_initialize :write_initial_state
    end
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
      file.puts %Q|
digraph #{workflow_name} {
  graph [#{graph_options}];
  node [shape=box];
  edge [len=1];
      |

      klass.workflow_spec.states.each do |state_name, state|
        file.puts %Q{  #{state.name} [label="#{state.name}"];}
        state.events.each do |event_name, event|
          meta_info = event.meta
          if meta_info[:doc_weight]
            weight_prop = ", weight=#{meta_info[:doc_weight]}"
          else
            weight_prop = ''
          end
          file.puts %Q{  #{state.name} -> #{event.transitions_to} [label="#{event_name.to_s.humanize}" #{weight_prop}];}
        end
      end
      file.puts "}"
      file.puts
    end
    `dot -Tpdf -o'#{fname}.pdf' '#{fname}.dot'`
    puts "
Please run the following to open the generated file:

open '#{fname}.pdf'

"
  end
end
