# encoding: utf-8

# Provides transaction rollback on halt. For now, you can choose between
# normal halt without any change to ordinary persistence (halt) or halt
# with transaction rollback (halt_with_rollback!), which will raise an
# ActiveRecord::Rollback exception.
# So this only works with ActiveRecord atm.

module Workflow
  module Transactional
    def new_transaction
      self.class.transaction(:requires_new => true) do
        yield
      end
    end

    def halt_with_rollback!(reason = nil)
      halt reason
      raise ActiveRecord::Rollback
    end

    def process_event!(*args)
      return_value = :unprocessed
      self.new_transaction do
        return_value = super(*args)
#         raise ActiveRecord::Rollback if self.halted?
      end
      return return_value == :unprocessed ? false : return_value
    end

  end # module Transactional
end # module Workflow
