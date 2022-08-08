# @note Inpspired by thread_safe gem's Util::CheapLockable mixin.
module ActiveRecord::Bogacs
  module ThreadSafe
    if defined? JRUBY_VERSION
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
