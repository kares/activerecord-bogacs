require 'active_record/connection_adapters/abstract_adapter'
require 'concurrent/utility/monotonic_time.rb'

module ActiveRecord
  module ConnectionAdapters
    AbstractAdapter.class_eval do

      attr_accessor :pool unless method_defined? :pool

      if method_defined? :owner # >= 4.2

        if ActiveRecord::VERSION::STRING > '5.2'

          # THIS IS OUR COMPATIBILITY BASE-LINE

        elsif ActiveRecord::VERSION::MAJOR > 4

          # this method must only be called while holding connection pool's mutex
          def lease
            if in_use?
              msg = "Cannot lease connection, ".dup
              if @owner == Thread.current
                msg << "it is already leased by the current thread."
              else
                msg << "it is already in use by a different thread: #{@owner}. " \
                       "Current thread: #{Thread.current}."
              end
              raise ActiveRecordError, msg
            end

            @owner = Thread.current
          end

          # this method must only be called while holding connection pool's mutex
          # @private AR 5.2
          def expire
            if in_use?
              if @owner != Thread.current
                raise ActiveRecordError, "Cannot expire connection, " \
                  "it is owned by a different thread: #{@owner}. " \
                  "Current thread: #{Thread.current}."
              end

              @idle_since = ::Concurrent.monotonic_time
              @owner = nil
            else
              raise ActiveRecordError, "Cannot expire connection, it is not currently leased."
            end
          end

        else

          # @private removed synchronization
          def lease
            unless in_use?
              @owner = Thread.current
            end
          end

          # @private added @idle_since
          def expire
            @owner = nil; @idle_since = ::Concurrent.monotonic_time
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
            @in_use = false; @owner = nil; @idle_since = ::Concurrent.monotonic_time
          end

        else

          alias :in_use? :owner

          def lease
            unless in_use?
              @owner = Thread.current
            end
          end

          def expire
            @owner = nil; @idle_since = ::Concurrent.monotonic_time
          end

        end

      end

      # this method must only be called while holding connection pool's mutex (and a desire for segfaults)
      def steal! # :nodoc:
        if in_use?
          if @owner != Thread.current
            pool.send :release, self, @owner # release exists in both default/false pool

            @owner = Thread.current
          end
        else
          raise ActiveRecordError, "Cannot steal connection, it is not currently leased."
        end
      end

      unless method_defined? :seconds_idle # >= 5.2

        # Seconds since this connection was returned to the pool
        def seconds_idle # :nodoc:
          return 0 if in_use?
          time = ::Concurrent.monotonic_time
          time - ( @idle_since || time )
        end

      end

    end
  end
end
