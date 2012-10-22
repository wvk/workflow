module Workflow
  module RemodelPersistence

    def self.happy_to_be_included_in?(klass)
      Object.const_defined?(:Remodel) and klass < Remodel::Entity
    end

    def load_workflow_state
      send(self.class.workflow_column)
    end

    def persist_workflow_state(new_value)
      update(self.class.workflow_column => new_value)
    end
  end
end

