require_relative 'Printer'

class Dashboard
	attr :hub

	def initialize(o={})
		@hub = Hub.new
		@p = Printer.new
		@hint_line = "{G}[{W}S{G}top]"
		@rq_lines = []
		@top_log_lines = []
		@state_part = ''
		$stderr = File.open 'errors.log', 'w'
		$stderr.sync = true
	end
	
	# -start
	def start(pH={})
		# on INT
		Signal.trap('INT') do
			at_exit do
				# *this cannot be called in the trap context
				stop!
			end
			exit
		end
		
		system 'clear'
		show_combo_hint
		@p.clear_rest_screen
		show_combo_hint  # 2 calls needed to fix problem on Linux that the first hint is cleared
		@p.back_cursor_to_cmd
	rescue
		stop! ERROR
	end
	
	def input_loop
		while text=((( $stdin.gets )))
			@last_answer = 'ok'
			begin
				# -cmd
				cmd = text.strip.downcase
				
				yield cmd
				
			rescue
				@last_answer = "Error: #$!"
			end

			break if @f_exit

			#. return cursor
			show_combo_hint
			@p.back_cursor_to_cmd
			Thread.new do
				sleep 1
				next if @f_exit
				reset_answer_line
			end
		end
	end

	# -log (-top log)
	def top_log(text)
		return if @f_exit
		data = {text:text, at:Time.now}
		@top_log_lines << data
		@top_log_lines.shift while @top_log_lines.length > $conf[:top_log_lines_N]
		with_delay do
			render_top_log
		end
		after_stale_delay do
			render_top_log
		end
	end

	def render_top_log
		@p.save_cursor
		@top_log_lines.reverse.each_with_index do |line_data, i|
			r = $conf[:screen_padding_top]+i+1
			color = stale?(line_data) ? '{dG}' : '{G}'
			fit_line = line_data[:text][0,$conf[:cell_cols_N]*2-10]
			@p.p [r, 1], @p.CL + "#{color}#{line_data[:at].strftime '%H:%M'} - "+fit_line
		end
		@p.restore_cursor
	end

	def reset_answer_line
		@p.save_cursor
		@p.p [3,1], @p.CL + "{dG}="
		@p.restore_cursor
	end

	def set_state(state=nil)
		@state_part =
			if state
				" - {W}#{state}{G}"
			else
				''
			end
		show_combo_hint
	end

	# -hint
	def show_combo_hint
		@p.save_cursor
		@p.go_to 1, 1
		@p.clear_line
		@p.p [1,1], @hint_line + @state_part
		@p.p [2,1], @p.CL + "{dG}>"
		@p.p [3,1], @p.CL + "{dG}= #{@last_answer}"
		@p.restore_cursor
	end

	def update_stats_line(line)
		return if @f_exit
		@res_line = line
	end

	def update_rq_lines(line)
		return if @f_exit
		@rq_lines << line
		@rq_lines.shift while @rq_lines.length > ($conf[:___] || 20)
	end
	def render_rq_lines
		Thread.new do
			loop do
				break if @f_exit
				@p.save_cursor

				# res line
				if @res_line
					@p.p [12, 30], @p.CRL + @res_line + ' -- this node'
				end

				@rq_lines.reverse.each_with_index do |line, i|
					r = 12+i+1
					fit_line = line[0,110]
					@p.p [r, 30], @p.CRL + fit_line
				end
				@p.restore_cursor
				sleep 0.5
			end
		end
	end

	def stop!(status=SHUTDOWN)
		@f_exit = true
		@p.stop
		@p.clear_rest_screen
		@p.go_to 3, 1
		@p.stop_go_to
		print 'Stopping'
		# wait for some delays
		# sleep 0.5
		if status==ERROR
			puts
			raise
		else
			exit status
		end
	end
	
	def stale?(line_data)
		line_data[:at] < Time.now - $conf[:stale_age_sec]
	end
	
	# accumulate changes — then render
	def with_delay
		#. cancel prev delay thread
		@delay_thread&.kill
		@delay_thread = Thread.new do
			sleep 0.1
			yield if !@f_exit
		end
	rescue ThreadError
	end
	
	def after_stale_delay
		#. cancel prev delay thread
		@stale_delay_thread&.kill
		@stale_delay_thread = Thread.new do
			sleep $conf[:stale_age_sec]
			yield if !@f_exit
		end
	rescue ThreadError
	end

	# -state
	def state
		@state ||= State.new(@state_fname).load
	end

	class State
		def initialize(fname='state.dat')
			@fname = fname
		end
		def load
			@data = eval(File.read @fname) rescue {}
			self
		end
		def save
			File.write @fname, @data.inspect
		end
		def [](key)
			@data[key]
		end
		def []=(key, val)
			@data[key] = val
			save
		end
	end

end