# @note Inpspired by thread_safe gem's Util::CheapLockable mixin.
module ActiveRecord::Bogacs
  module ThreadSafe
    engine = defined?(RUBY_ENGINE) && RUBY_ENGINE
    if engine == 'rbx'
      module Synchronized
        # Making use of the Rubinius' ability to lock via object headers to avoid
        # the overhead of the extra Mutex objects.
        def synchronize
          ::Rubinius.lock(self)
          begin
            yield
          ensure
            ::Rubinius.unlock(self)
          end
        end
      end
    elsif engine == 'jruby'
      module Synchronized
        require 'jruby'
        # Use Java's native synchronized (this) { wait(); notifyAll(); } to avoid
        # the overhead of the extra Mutex objects
        def synchronize
          ::JRuby.reference0(self).synchronized { yield }
        end
      end
    else
      require 'thread'; require 'monitor'
      # on MRI fallback to built-in MonitorMixin
      Synchronized = MonitorMixin
    end
  end
end