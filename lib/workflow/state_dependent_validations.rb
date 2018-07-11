require 'active_model/validations'

module Workflow
  module StateDependentValidations
    module StateDependency

      def self.included(base)
        base.prepend Validations
      end

      module Validations

        def validate(record)
          if not record.respond_to?(:current_state) or
              perform_validation_for_state?(record.current_state) or
              perform_validation_for_transition?(record.in_transition) or
              perform_validation_for_transition?("#{record.in_exit}_exit") or
              perform_validation_for_transition?("#{record.in_entry}_entry")
            super(record)
          end
        end

        protected
        def perform_validation_for_state?(state)
          (unless_in_state_option.empty? and if_in_state_option.empty? and
            unless_in_transition_option.empty? and if_in_transition_option.empty?) or
              (if_in_state_option.any? and if_in_state_option.include?(state.to_s)) or
              (unless_in_state_option.any? and not unless_in_state_option.include?(state.to_s))
        end

        def perform_validation_for_transition?(transition)
          (unless_in_state_option.empty? and if_in_state_option.empty? and
            unless_in_transition_option.empty? and if_in_transition_option.empty?) or
              (if_in_transition_option.any? and if_in_transition_option.include?(transition.to_s)) or
              (unless_in_transition_option.any? and not unless_in_transition_option.include?(transition.to_s))
        end

        def if_in_state_option
          @if_in_state_option ||= [options[:if_in_state]].flatten.compact.collect(&:to_s)
        end

        def unless_in_state_option
          @unless_in_state_option ||= [options[:unless_in_state]].flatten.compact.collect(&:to_s)
        end

        def if_in_transition_option
          @if_in_transition_option ||= [options[:if_in_transition]].flatten.compact.collect(&:to_s)
        end

        def unless_in_transition_option
          @unless_in_transition_option ||= [options[:unless_in_transition]].flatten.compact.collect(&:to_s)
        end
      end
    end

  end
end

module ActiveModel::Validations
  [AcceptanceValidator, ConfirmationValidator, ExclusionValidator,
  FormatValidator, InclusionValidator, LengthValidator,
  NumericalityValidator, PresenceValidator].each do |validator|
    validator.send :include, Workflow::StateDependentValidations::StateDependency
  end
end
