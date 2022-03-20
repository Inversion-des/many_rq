require 'json'
require_relative 'libs/Hub'
require_relative 'libs/Dashboard'
require_relative 'libs/ManyRq'

SHUTDOWN = 0
ERROR = 1
RESTART = 2

class KnownError < StandardError;end
class PermissionDenied < KnownError;end

class Array
	def avrg
		return nil if empty?
		sum.fdiv size
	end
end
class Numeric
	def limit_min(min)
		[self, min].max
	end
	def limit_max(max)
		[self, max].min
	end
end

class Mutex
	alias :sync synchronize
	def sync_if_needed
		if owned?
			yield
		else
			synchronize do
				yield
			end
		end
	end
end