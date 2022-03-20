# frozen_string_literal: true
require_relative '_common'

$conf = {
	top_log_lines_N: 3,
	stale_age_sec: 5,
	screen_padding_top: 3,
	cell_cols_N: 75,
}


class Node < Dashboard
	def initialize
		super
		@hint_line = "{G}[{W}tN{G}=threadsN, {W}P{G}ause/resume, {W}R{G}estart, {W}Q{G}uit]"
		@state_fname = 'node_state.dat'
		@many_rq = ManyRq.new
		@f_stopped = false
		state[:threads_n] ||= 1
		@many_rq.set_threads state[:threads_n]
		@conf = {}
		@last_sent_valsH = {}
		controller
	end

	def controller
		@many_rq.hub.on :error do |e, error_str|
			top_log error_str
			cmd_do 'stop'
		end
		@many_rq.hub.on :fire_result do |e, line|
			update_rq_lines line
		end
		@many_rq.hub.on :stats_update do |e, line|
			update_stats_line line
		end
	end

	# -start
	def start
		if !state[:node_name]
			print "Name your node (12 chars max): "
			state[:node_name] = ((( $stdin.gets.chomp )))
		end
		if !state[:hub_host]
			print "Hub IP: "
			state[:hub_host] = ((( $stdin.gets.chomp )))
		end

		super

		connect_to_Sync_server_part
		reconnect_if_needed
		render_rq_lines

		# input -cmd
		input_loop do |cmd|
			case cmd
				when 'r', 'restart'
					stop! RESTART

				when 'q', 'quit'
					stop!

				when 'p', 'pause'
					@many_rq.pause_resume
					send_node_data
					if state[:paused]=@many_rq.paused?
						set_state 'paused'
					else
						set_state
					end

				# set threads count
				when /^t(\d+)/
					state[:threads_n] = $1.to_i
					f_was_running = !@f_stop
					@many_rq.stop
					@many_rq.set_threads state[:threads_n]
					send_node_data
					if f_was_running
						@many_rq.start_in_thr
					end
					
				else
					@last_answer = 'wrong command: '+cmd
			end
		end
	end

	def reconnect_if_needed
		Thread.new do
			f_first_iteration = true
			loop do
				break if @f_exit

				if !@server_part.online?
					if @last_sent_valsH[:online] != false
						@last_sent_valsH[:online] = false
					end
					sleep 2
					connect_to_Sync_server_part
					sleep 2
					redo
				end
				#! TEMP
				# print '.'
				sleep 0.5
			end
		end
	end

	def connect_to_Sync_server_part
		@server_part = Sync_server_part_connection.new(self,  @conf)
		send_node_data
	end

	def send_node_data
		@server_part.cmd('node_data', {
			name: state[:node_name],
			threads: @many_rq.threads_n,
			# paused: @many_rq.paused?,
			state: case
				when @many_rq.paused?; 'paused'
				when @f_stopping; 'stopping'
				when @f_stopped; 'stopped'
				else 'working'
			end
		})
	end

	# cmd_do -cmd (from server part)
	def cmd_do(cmd, data=nil)
		# top_log cmd
		# top_log data.to_json
		case cmd
			when 'log'
				top_log 'server: ' + data
			when 'error'
				top_log '{R}server: ' + data

			when 'update_stats'
				@p.save_cursor
				line = data
				@p.p [8, 1], line
				@p.restore_cursor

			when 'update_nodes_list'
				@p.save_cursor
				lines = data
				@p.p [9, 1], lines.join("\n")
				@p.restore_cursor

			when 'update_health_line'
				@p.save_cursor
				lines = data
				@p.p [8, 30], lines[0]  # target
				line = lines[1]  # health bar
				# if state[:alt_bar_char]
				# 	line.tr! '▓▒', 'O-'
				# end
				@p.p [9, 30], line
				@p.p [10, 30], lines[2]  # response time
				@p.restore_cursor

			when 'set_target'
				top_log "set target: #{data}"
				@many_rq.set_target data
			when 'start'
				target = data
				top_log 'start - '+target
				@many_rq.set_target data
				@many_rq.start_in_thr
				@f_stopped = false
				send_node_data
			when 'stop'
				top_log 'stop'
				@f_stopping = true
				send_node_data
				@many_rq.stop
				@f_stopping = false
				@f_stopped = true
				send_node_data
			else
				top_log "!! Unknown cmd: "+cmd
		end
	end

end


class Sync_server_part_connection

	def initialize(worker, pH={})
		@worker = worker
		@sending_to_server_part_mutex = Mutex.new

		@worker.top_log "Connecting to the RqHub (#{worker.state[:hub_host]})..."
		hostname = worker.state[:hub_host]
		port = pH[:port] || 2402
		@server = TCPSocket.open(hostname, port)
		#. should be same as in ClientHelper
		@msg_splitter = "\r\r\n\n"
		@worker.top_log 'connected'
		@online = true
		send(:hello => 1, :pass => pH[:pass])


		# start pings with delay
		Thread.new do
			sleep 10
			# (<!)
			next if !@online

			begin
				loop do
					sleep 5
					print 'ping'
				end
			rescue
				@worker.top_log 'Error in: ping loop'
				@worker.top_log $!.to_s
				@worker.top_log $@[0]
				@online = false
			end
		end

		# listen messages from server part
		Thread.new do begin
			while msg = @server.gets((( @msg_splitter )))
				if msg.include? "[[BIN_FILE]]"
					@worker.file_received msg.sub(/^\[\[BIN_FILE\]\]/, '').chomp(@msg_splitter)
				# json expected
				else
					msg.chomp!
					if msg == 'stop'
						f_client_alive = false
						break
					end
					process_server_part_data JSON.parse(msg)
				end
			end
		#  Errno::ECONNRESET
		rescue
			@worker.top_log 'Error in: listen messages from server part'
			@worker.top_log $!.to_s
			@worker.top_log $@[0]
		ensure
			@worker.top_log 'disconnected'
			@online = false
		end end

	#  Errno::ECONNREFUSED
	rescue
		@worker.top_log $!.to_s
		@worker.top_log 'no server'
		@online = false
	end

	def online?
		@online
	end

	def process_server_part_data(msg)
		if msg['hello']
		elsif msg['cmd']
			@worker.cmd_do msg['cmd'], msg['data']
		end
	rescue KnownError
		@worker.top_log "{R}Error: #{$!}"
	rescue
		@worker.top_log 'Error in: process_server_part_data'
		@worker.top_log $!.to_s
		@worker.top_log $@[0]
	end


	def print(msg)
		return if !@server
		# *probably ping breaks sending of file so we added a mutex here
		@sending_to_server_part_mutex.synchronize do
			@server.puts msg+@msg_splitter
		end
	# , Errno::ECONNRESET
	# *always when send 'ping'
	#  Errno::EPIPE
	rescue
		# @worker.top_log 'Errno::EPIPE : '+msg
		# @worker.top_log $!.to_s
	end
	def puts(msg)
		return if !@server
		print msg
		print
	end
	def send(data)
		return if !@server
		print data.to_json
	end
	def cmd(cmd, data=nil)
		send(:cmd => cmd, :data => data)
	end

end   # class Sync_server_part_connection


Node.new.start

