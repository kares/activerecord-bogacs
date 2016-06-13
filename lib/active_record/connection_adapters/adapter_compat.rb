require 'active_record/connection_adapters/abstract_adapter'

module ActiveRecord
  module ConnectionAdapters
    AbstractAdapter.class_eval do

      attr_accessor :pool unless method_defined? :pool

      if method_defined? :owner # >= 4.2

        attr_reader :last_use

        if ActiveRecord::VERSION::MAJOR > 4

          # @private added @last_use
          def lease
            if in_use?
              msg = 'Cannot lease connection, '
              if @owner == Thread.current
                msg += 'it is already leased by the current thread.'
              else
                msg += "it is already in use by a different thread: #{@owner}. Current thread: #{Thread.current}."
              end
              raise ActiveRecordError, msg
            end

            @owner = Thread.current; @last_use = Time.now
          end

        else

          # @private removed synchronization + added @last_use
          def lease
            if in_use?
              if @owner == Thread.current
                # NOTE: could do a warning if 4.2.x cases do not end up here ...
              end
            else
              @owner = Thread.current; @last_use = Time.now
            end
          end

        end

      else

        attr_reader :owner

        if method_defined? :in_use?

          if method_defined? :last_use

            def lease
              unless in_use?
                @owner = Thread.current
                @in_use = true; @last_use = Time.now
              end
            end

          else

            def lease
              unless in_use?
                @owner = Thread.current
                @in_use = true
              end
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

      end

    end
  end
end