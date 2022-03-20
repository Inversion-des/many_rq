class Hub
	def initialize
		@subs_by_msg = Hash.new {|h, k| h[k]=[] }
	end
	def fire(msg, *data)
		for blk in @subs_by_msg[msg]
			blk.call msg, *data
		end
	end
	def on(*msgs, &blk)
		for msg in msgs
			@subs_by_msg[msg] << blk
		end
	end
end
