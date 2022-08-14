require 'concurrent/thread_safe/util/cheap_lockable.rb'

# @note Inpspired by thread_safe gem's Util::CheapLockable mixin.
module ActiveRecord::Bogacs
  module ThreadSafe
    if defined? JRUBY_VERSION
      module Synchronized
        if defined? ::JRuby::Util.synchronized # since JRuby 9.3
          def synchronize
            ::JRuby::Util.synchronized(self) { yield }
          end
        else
          require 'jruby'
          def synchronize
            ::JRuby.reference0(self).synchronized { yield }
          end
        end
      end
    else
      require 'concurrent/thread_safe/util/cheap_lockable.rb'

      module Synchronized
        include ::Concurrent::ThreadSafe::Util::CheapLockable
        alias_method :synchronize, :cheap_synchronize
        public :synchronize
      end
    end
  end
end
