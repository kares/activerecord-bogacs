require 'active_record/connection_adapters/abstract_adapter'

module ActiveRecord
  module ConnectionAdapters
    AbstractAdapter.class_eval do

      attr_accessor :pool unless method_defined? :pool

      unless method_defined? :owner

        attr_reader :owner

        if method_defined? :in_use?

          def lease
            unless in_use?
              @owner = Thread.current; @in_use = true
            end
          end

          def expire
            @in_use = false; @owner = nil
          end

        else

          alias :in_use? :owner

          def lease
            unless in_use?
              @owner = Thread.current
            end
          end

          def expire
            @owner = nil
          end

        end

        alias :in_use? :owner

        def lease
          unless in_use?
            @owner = Thread.current
          end
        end

        def expire
          @owner = nil
        end

      end

    end
  end
end