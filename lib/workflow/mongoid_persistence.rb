module Workflow
  module MongoidPersistence

    def self.happy_to_be_included_in?(klass)
      Object.const_defined?(:Mongoid) and klass.include? Mongoid::Document
    end

    def self.included(klass)
      klass.after_initialize :write_initial_state
    end

    def load_workflow_state
      read_attribute(self.class.workflow_column)
    end

    # implementation of abstract method: saves new workflow state to DB
    def persist_workflow_state(new_value)
      self.write_attribute(self.class.workflow_column, new_value.to_s)
      self.save!
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
end

