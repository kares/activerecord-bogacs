# @note Inpspired by thread_safe gem's Util::CheapLockable mixin.
module ActiveRecord::Bogacs
  module ThreadSafe
    if defined? JRUBY_VERSION
      module Synchronized
        require 'jruby'

        if defined? ::JRuby::Util.synchronized # since JRuby 9.3
          def synchronize
            ::JRuby::Util.synchronized(self) { yield }
          end
        else
          def synchronize
            ::JRuby.reference0(self).synchronized { yield }
          end
        end
      end
    else
      require 'thread'; require 'monitor'
      # on MRI fallback to built-in MonitorMixin
      Synchronized = MonitorMixin
    end
  end
end
