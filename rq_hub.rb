# frozen_string_literal: true
require 'socket'
require_relative '_common'

$conf = {
	top_log_lines_N: 3,
	stale_age_sec: 5,
	screen_padding_top: 3,
	cell_cols_N: 75,
}


class RqHub < Dashboard

	def initialize
		super
		@hint_line = "{G}[{W}S{G}tart/{W}S{G}top, {W}T{G}arget NAME, {W}R{G}estart, {W}Q{G}uit]"
		@clients = []
		@state_fname = 'hub_state.dat'
		@many_rq = ManyRq.new
		@many_rq.set_threads 5
		state[:stopped] = true if state[:stopped].nil?
		@calibration_every_n_mins = 15
		@calibration_interval_s = @calibration_every_n_mins*60
		@calibration_time_s = 20
		@calibration_last_moment = Time.now
		@health = {}
		@conf = {
			port: 2402
		}
		controller
	end

	def controller
		@hub.on :client_connected do |e, client|
			# (<!) detect already connected
			if @clients.find {|c| c.ip == client.ip && c != client }
				top_log "{R}rejected client: #{client.ip_data}"
				client.cmd 'error', 'already connected'
				sleep 0.5
				client.destroy
				next
			end

			top_log "client connected: #{client.ip_data}"
			if @f_just_started
				client.cmd 'stop'
			elsif !state[:stopped] && state[:target] && !@f_calibrating
				client.cmd 'start', state[:target]
			end
		end

		@many_rq.hub.on :error do |e, error_str|
			top_log error_str
			@many_rq.stop
		end
		@many_rq.hub.on :fire_result do |e, line|
			update_rq_lines line
		end
		@many_rq.hub.on :stats_update do |e, line|
			update_stats_line line
		end
		@many_rq.hub.on :health_update do |e, data|
			@health.update data
		end
	end

	# -start
	def start
		super

		run_server
		render_rq_lines
		render_health_line
		@f_just_started = true

		# restore state
		if state[:target]
			@many_rq.set_target state[:target]
			@many_rq.fire  # to show the current target
		end
		if !state[:stopped]
			# wait for clients connected and stopped
			sleep 3
			sleep 1 until @clients.all? {|c| ['paused','stopped'].include?(c.node_data['state']) }
			sleep 5
			# restart
			start_many_rq
		end
		@f_just_started = false

		# input -cmd
		input_loop do |cmd|
			# -cmd
			# expand shortcuts
			cmd = case cmd
				when 's'
					state[:stopped] ? 'start' : 'stop'
				else cmd
			end
			case cmd
				when 'r', 'restart'
					stop! RESTART

				when 'q', 'quit'
					stop!

				when 'start'
					if state[:target]
						start_many_rq
					else
						@last_answer = 'target not defined'
					end

				when 'stop'
					state[:stopped] = true
					set_state 'stopped'
					@f_calibrating = false
					@thr1.kill
					@thr2.kill
					@many_rq.stop
					for client in @clients
						client.cmd 'stop'
					end

				# set tarteg by name
				when /^t(?:arget)? (\S+)/
					name = $1
					state[:target] = name
					@many_rq.set_target state[:target]
					for client in @clients
						client.cmd 'set_target', name
					end

				else
					@last_answer = 'wrong command: '+cmd
			end
		end
	end

	# (>>>)
	def start_many_rq
		state[:stopped] = false
		set_state 'working'
		@many_rq.start_in_thr
		@calibration_last_moment = Time.now
		@f_calibrating = true
		@thr1 = Thread.new do
			sleep @calibration_time_s
			next if state[:stopped]

			# save base values
			@health[:ok_perc_base] = @health[:ok_perc]
			@health[:failed_perc_base] = @health[:failed_perc]
			@health[:time_ms_avarage_base] = @health[:time_ms_avarage]

			@f_calibrating = false
			for client in @clients
				client.cmd 'start', state[:target]
			end
		end
		@thr2 = Thread.new do
			sleep @calibration_interval_s
			for client in @clients
				client.cmd 'stop'
			end
			@many_rq.stop
			@many_rq.reset_last_results
			sleep 1 until @clients.all? {|c| ['paused','stopped'].include?(c.node_data['state']) }
			sleep 5
			next if state[:stopped]
			# (>>>)
			start_many_rq
		end
	end

	def run_server
		Thread.new do
			server = TCPServer.open @conf[:port]
			top_log "Server ready. Port: #{@conf[:port]}"
			loop do
				Thread.new((( server.accept ))) do |client|
					#    client.puts(Time.now.ctime) # Send the time to the client
					#	client.puts "Closing the connection. Bye!"

					client_helper = ClientHelper.new(:client => client, rq_hub:self, :conf => @conf)
					@clients << client_helper
					update_stats

					f_client_alive = true
					Thread.new do begin
						msg_splitter = "\r\r\n\n"
						while msg = client.gets((( msg_splitter )))
							if msg.include? "[[BIN_FILE]]"
								client_helper.raise_if_not_authorized!
								client_helper.file_received msg.sub(/^\[\[BIN_FILE\]\]/, '').chomp(msg_splitter)
							# json or 'ping' expected
							else
								msg.chomp!(msg_splitter)
								if msg == 'ping'
									# dead client detection
									# restart timer
									@offline_detector_thr&.kill
									@offline_detector_thr = Thread.new do
										sleep 20
										raise "dead client: #{client_helper.node_data['name']}"
									end
									# puts 'ping'
									next
								end
								client_helper.process_client_data JSON.parse(msg)
							end
						end   # while
					rescue PermissionDenied
						top_log $!.to_s
					rescue JSON::ParserError
						top_log $!.to_s
						top_log msg[0..100]
						# print if msg == ''
					rescue Errno::ECONNRESET, Errno::ETIMEDOUT
						if client_helper.online?
							top_log $!.to_s
						end
					rescue
						if client_helper.online?
							top_log $!.to_s
						end
					ensure
						f_client_alive = false
					end end   # Thread

					loop do
						break if !f_client_alive
						# print '.'
						# client.puts 'ping'
						sleep 0.5
					end

					top_log 'Client disconnected'
					client_helper.destroy
					client.close
					@clients.delete client_helper
					update_stats
					update_nodes_list
				end
			end
		end
	end

	C_col_W = 29
	def update_stats
		@p.save_cursor
		total_threads = @clients.sum do |node|
			d = node.node_data
			d['state']!='paused' && d['threads'] || 0
		end
		line = "%-#{C_col_W}s" % "Nodes: #{@clients.count}, Threads: #{total_threads}"
		fit_line = line[0,C_col_W]
		
		@p.p [8, 1], fit_line
		@p.restore_cursor

		for client in @clients
			client.cmd 'update_stats', line
		end		
	end


	# -list
	def update_nodes_list
		@p.save_cursor
		sorted_by_active_threads = @clients.sort_by do |node|
			d = node.node_data
			[d['state']=='paused'?1:0, -(d['threads']||0)]
		end
		lines = sorted_by_active_threads.map do |node|
			d = node.node_data
			# paused_part = ' (paused)' if d['state']=='paused'
			color = ['paused','stopped'].include?(d['state']) ? '{dG}' : ''
			# 2 last groups of IP

			name_part = (d['name']||'?')[0,12]+'^'+node.ip_part
			stopping_part = '.' if ['stopping','stopped'].include?(d['state'])
			line = color+"%-#{C_col_W}s" % " #{name_part} - #{d['threads']}#{stopping_part}{G}"
			fit_line = line[0,C_col_W+6]  #+6 due to colors
		end
		lines << ' '*C_col_W  # clear the line next to the last
		@p.p [9, 1], lines.join("\n")
		@p.restore_cursor

		for client in @clients
			client.cmd 'update_nodes_list', lines
		end		
	end


	# -health
	def render_health_line
		Thread.new do
			loop do
				break if @f_exit
				if @health[:ok_perc]
					@p.save_cursor

					# target line
					state_part = state[:stopped] ? 'stopped' : 'working'
					line1 = @p.CRL + "{Y}#{state[:target]}{G} - #{state_part}"
					@p.p [8, 30], line1

					@health[:ok_perc_base] ||= @health[:ok_perc]
					@health[:failed_perc_base] ||= 0
					@health[:time_ms_avarage_base] ||= @health[:time_ms_avarage]

					bar_len = 50
					# ! TEMP
					# @health[:ok_perc] = 50
					# @health[:failed_perc] = 25

					ok_perc = @health[:ok_perc]
					ok_k = ok_perc.to_f/100
					ok_len = (bar_len * ok_k).round
					ok_part = "\e[1;32m#{'▓'*ok_len}"  # green

					failed_perc = @health[:failed_perc]
					# ignore base failed % (show as rest part)
					if !@f_calibrating
						failed_perc -= @health[:failed_perc_base]
					end
					failed_k = failed_perc.to_f/100
					failed_len = (bar_len * failed_k).round.limit_min 0
					failed_part = "{R}#{'▓'*failed_len}"  # dark red

					rest_len = (bar_len - (ok_len + failed_len)).limit_min 0
					rest_part = "{dG}#{'▒'*rest_len}"  # dark grey

					if @f_calibrating
						seconds_done = Time.now - @calibration_last_moment
						done_k = seconds_done.to_f / @calibration_time_s
						done_pers = (done_k * 100).to_i
						mode = "calibrating #{done_pers}%"
					else
						mode = 'results'
						added_pers = (@health[:failed_perc] - @health[:failed_perc_base]).limit_min 0
						added_pers_part = " ({R}+%.1f{G})" % added_pers
					end
					

					line2 = @p.CRL + ok_part + failed_part + rest_part + "{G} - %.1f %% failed#{added_pers_part} (%s)" % [@health[:failed_perc], mode]
					line2.tr! '▓▒', 'O-'  # do not use ascii chars (problems in some consoles)
					@p.p [9, 30], line2

					# average response time
					time_ms_avarage = @health[:time_ms_avarage]
					added_time_ms = 0
					added_bar = ''
					if !@f_calibrating
						# show base part as green
						time_ms_avarage = [@health[:time_ms_avarage], @health[:time_ms_avarage_base]].min
						# added part (red)
						added_time_ms = (@health[:time_ms_avarage] - @health[:time_ms_avarage_base]).limit_min 0
						time_s = added_time_ms.to_f / 1000
						bar_len = (5*time_s).round   # 5o = 1s — o = 200ms
						plus = bar_len - 25  # 5s max
						if plus > 0
							bar_len = 25
							plus_part = "+#{plus}"
						end
						added_bar = "{R}%s#{plus_part}{G}" % ('o'*bar_len)
						added_ms_part = " ({R}+#{added_time_ms}{G})"

						# next calibration
						period_s = @calibration_interval_s
						seconds_done = Time.now - @calibration_last_moment
						seconds_left = (period_s - seconds_done).to_i
						if !state[:stopped] && seconds_left > 0
							mins = seconds_left.to_f / 60
							next_calib_part = " (next calibration in %.1f mins)" % mins
						end
					end
					time_s = time_ms_avarage.to_f / 1000
					bar_len = (5*time_s).round   # 5o = 1s — o = 200ms
					plus = bar_len - 25  # 5s max
					if plus > 0
						bar_len = 25
						plus_part = "+#{plus}"
					end
					bar = "\e[1;32m%s#{plus_part}{G}" % ('o'*bar_len)
					line3 = @p.CRL + bar + added_bar + " - %d ms#{added_ms_part} average#{next_calib_part}" % [@health[:time_ms_avarage]]
					@p.p [10, 30], line3

					@p.restore_cursor

					for client in @clients
						client.cmd 'update_health_line', [line1, line2, line3]
					end
				end
				sleep 0.5
			end
		end
		
	end


end   # class RqHub


class ClientHelper
	attr :node_data
	def initialize(pH={})
		@rq_hub = pH[:rq_hub]
		@node_data = {}
		@module_name = File.basename($0, '.rb')
		@client = pH[:client]
		@conf = pH[:conf]
		@root_dir = nil
		@receiving_file_path = nil
		# should be same as in Sync_server_part_connection
		@msg_splitter = "\r\r\n\n"
		@monitoring_list = []
		@monitoring_files_states = {}
		@cur_git_branch = nil
		@f_monitoring = false
		@f_branch_monitoring = false
		@first_msg_received = false
		@f_authorized = false

		# Thread.new do
		# 	sleep 2
		# 	cmd 'start'
		# 	sleep 5
		# 	cmd 'stop'
		# end
	end

	def ip_data
		@ip_data ||= @client.peeraddr(:hostname).join '|'
	end

	def ip
		@ip ||= @client.peeraddr(:hostname).last
	end

	def ip_part
		@ip_part ||= begin
			ip[/\d+\.\d+$/] || ip
		end
	end

	def raise_if_not_authorized!
		# raise PermissionDenied if @first_msg_received && !@f_authorized
	end

	def process_client_data(msg)
		@first_msg_received = true
		if msg['hello']
			@f_authorized = msg['pass'] == @conf[:pass]
			raise_if_not_authorized!
			@rq_hub.hub.fire :client_connected, self
		end

		raise_if_not_authorized!

		if msg['cmd']
			cmd_do msg['cmd'], msg['data']
		end
	rescue PermissionDenied
		raise
	rescue KnownError
		@rq_hub.top_log "{R}Error: #{$!}"
	rescue
		@rq_hub.top_log $!.to_s
		@rq_hub.top_log $@[0]
	end

	# -cmd (-do) - commands from the client
	def cmd_do(cmd, data)
		case cmd
			when 'node_data'
				@rq_hub.top_log data.to_json
				@node_data = data
				@rq_hub.update_stats
				@rq_hub.update_nodes_list
			# when 'log'
			# 	@rq_hub.top_log data['msg']
			else
				@rq_hub.top_log "!! Unknown cmd: "+cmd
		end
	end

	def send(msg)
		return if !@client
		@client.puts msg+@msg_splitter
	rescue
		@rq_hub.top_log '(send) '+$!.inspect
	end
	def send_json(data)
		return if !@client
		send data.to_json
	end
	def cmd(cmd, data=nil)
		send_json(:cmd => cmd, :data => data)
	end

	def online?
		!@f_destroyed
	end

	def destroy
		return if @f_destroyed
		@f_destroyed = true
		@client.close
	end
end


RqHub.new.start
