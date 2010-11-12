module Workflow
  module StateDependentValidations
    module StateDependency

      def self.included(base)
        base.send :alias_method_chain, :validate, :state_dependency
      end

      def validate_with_state_dependency(record)
        if not record.respond_to?(:current_state) or perform_validation_for_state?(record.current_state)
          validate_without_state_dependency(record)
        end
      end

      protected
      def perform_validation_for_state?(state)
        (unless_in_state_option.empty? and if_in_state_option.empty?) or
            (if_in_state_option.any? and if_in_state_option.include?(state.to_s)) or
            (unless_in_state_option.any? and not unless_in_state_option.include?(state.to_s))
      end

      def if_in_state_option
        @if_in_state_option ||= [options[:if_in_state]].flatten.compact.collect(&:to_s)
      end

      def unless_in_state_option
        @unless_in_state_option ||= [options[:unless_in_state]].flatten.compact.collect(&:to_s)
      end
    end

  end
end

unless defined? ActiveModel::Validations
  module ActiveModel::Validations
    [AcceptanceValidator, ConfirmationValidator, ExclusionValidator,
    FormatValidator, InclusionValidator, LengthValidator,
    NumericalityValidator, PresenceValidator].each do |validator|
      validator.send :include, Workflow::StateDependentValidations::StateDependency
    end
  end
else
  raise 'state dependent validation only works with ActiveModel::Validations'
end

