=begin
workers = Workers.new 10
workers << -> do
	...
end
workers.wait_when_done

# to limit number of added tasks:
loop do
	# puts @workers.queue.size
	break if @workers.queue.size < 50
	sleep 0.5
end
=end
class Workers
	attr :queue
	def initialize(n)
		n = 1 if n < 1  # 1 is minimum
		@queue = Queue.new
		@threads = n.times.map do
			Thread.new do
				loop do
					task = Thread.current[:task] = ((( @queue.pop )))
					task.call
					Thread.current[:task] = nil
				end
			end
		end
	end
	def << (task)
		@queue << task
	end
	def done?
		@threads.none? {|w| w[:task] }
	end
	def wait_when_done
		sleep 0.010 until @queue.empty? && done?
	end
	def stop
		@queue.clear
	end
end