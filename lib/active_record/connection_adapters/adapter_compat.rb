require 'active_record/connection_adapters/abstract_adapter'

module ActiveRecord
  module ConnectionAdapters
    AbstractAdapter.class_eval do

      attr_accessor :pool unless method_defined? :pool

      if method_defined? :owner # >= 4.2

        if ActiveRecord::VERSION::STRING > '5.2'

          # THIS IS OUR COMPATIBILITY BASE-LINE

        elsif ActiveRecord::VERSION::MAJOR > 4

          # @private added @idle_since
          # this method must only be called while holding connection pool's mutex
          def expire
            if in_use?
              if @owner != Thread.current
                raise ActiveRecordError, "Cannot expire connection, " \
                  "it is owned by a different thread: #{@owner}. " \
                  "Current thread: #{Thread.current}."
              end

              @owner = nil; @idle_since = monotonic_time
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
            @owner = nil; @idle_since = monotonic_time
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
            @in_use = false; @owner = nil; @idle_since = monotonic_time
          end

        else

          alias :in_use? :owner

          def lease
            unless in_use?
              @owner = Thread.current
            end
          end

          def expire
            @owner = nil; @idle_since = monotonic_time
          end

        end

      end

      unless method_defined? :seconds_idle # >= 5.2

        if ActiveRecord::Bogacs::ThreadSafe.load_monotonic_clock(false)
          include ActiveRecord::Bogacs::ThreadSafe

          def monotonic_time; MONOTONIC_CLOCK.get_time end
          private :monotonic_time

        else

          def monotonic_time; nil end
          private :monotonic_time

          warn "activerecord-bogacs failed to load 'concurrent-ruby', '~> 1.0', seconds_idle won't work" if $VERBOSE

        end

        # Seconds since this connection was returned to the pool
        def seconds_idle # :nodoc:
          return 0 if in_use?
          time = monotonic_time
          time - ( @idle_since || time )
        end

      end

    end
  end
end
