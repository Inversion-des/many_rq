class Printer

	CL = "\e[2K"
	@@mutex = Mutex.new

	def initialize
		@last_position = [1,1]
	end
	# clear line
	def CL
		"\e[2K"
	end
	# clear the rest of the line (from cursor)
	def CRL
		"\e[K"
	end
	def clear_line
		print CL
	end
	def clear_rest_screen
		print "\e[J"
	end
	def go_to(r, c)
		return if @f_go_to_stopped
		print "\e[%d;%dH" % [r, c]
	end
	# @p.p [1,30], 'text'
	# @p.p 'text' — prints in current cursor position
	def p(rc, text=nil)
		return if @f_stopped
		@@mutex.sync_if_needed do
			next if @f_stopped
			if !text
				text = rc
				rc = nil
			end
			go_to *rc if rc
			print process(text)
			print process '{G}'
		end
	rescue ThreadError
	end

	def stop
		@f_stopped = true
	end
	def stop_go_to
		@f_go_to_stopped = true
	end

	def save_cursor
		@@mutex.lock
		print "\e[s"
	end
	def restore_cursor
		print "\e[u"
		@@mutex.unlock
	end

	def back_cursor_to_cmd
		go_to 2, 2
	end

	def chars_count(text)
		colors_chars_count = 0
		text.gsub /{\w+}/ do |m|
			colors_chars_count += m.length
		end
		text.length - colors_chars_count
	end

	private

	def process(text)
		text
			.gsub(/{W}/, "\e[1;37m")   # white
			.gsub(/{G}/, "\e[0;39m")   # default gray
			.gsub(/{dG}/, "\e[1;30m")   # dark gray
			.gsub(/{R}/, "\e[1;31m")   # red
			.gsub(/{dR}/, "\e[0;31m")   # dark red
			.gsub(/{Y}/, "\e[1;33m")   # yellow
			.gsub(/{dY}/, "\e[0;33m")   # dark yellow
	end

end