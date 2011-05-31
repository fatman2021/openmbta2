require 'sequel'
DB = Sequel.connect 'postgres:///mbta'
# don't put semicolon at the end of sequel query
require 'yaml'
require 'set'

class TransitTrips

  class NoRouteData < StandardError; end

  NEXT_ARRIVALS_MAX = 4

  attr :trips, :grid, :stops
  def initialize(route, direction_id)
    @route = route # a route name
    @direction_id = direction_id # let direction by 0 or 1
    @trips = Hash.new {|hash, key| hash[key] = []}
    @stops = {}
    @next_arrivals = {}
    calc_next_arrivals
    make_grid
    fix_grid_stop_ids
  end

  def result
    r = {
      stops: use_int_keys(@stops),
      first_stop: @first_stops.to_a,
      imminent_stop_ids: imminent_stop_ids.map{|x| to_int_key(x).to_s}.uniq,
      ordered_stop_ids: ordered_stop_ids,
      region: region,
      grid: @grid
    }

    if @next_arrivals.empty?
      r[:message] = {title: 'Alert', body: 'No more trips for the day'}
    end
    r
  end

  def calc_next_arrivals
    #query = "select stops.stop_name, stops.stop_id, stops.parent_station, stops.stop_code, st.* from stop_times_today(?, ?) st join stops using(stop_id)"
    query = "select stops.stop_name, st.* from stop_times_today(?, ?) st join stops using(stop_id)"
    DB[query, @route, @direction_id].each do |row|
      stopping = { 
        arrival_time: row[:arrival_time], 
        stop_name: row[:stop_name], 
        stop_sequence: row[:stop_sequence],
        stop_id: row[:stop_id],
        trip_id: row[:trip_id]
      }
      @trips[row[:trip_id]] << stopping
      # fill in these values later
      @stops[row[:stop_id]] = {}
    end
    if @trips.empty?
      raise NoRouteData
    end
    DB["select * from stops where stop_id in ?", @stops.keys].each do |row|
      @stops[row[:stop_id]] = convert_stop_data(row)
    end
  end

  def make_grid
    @grid = [] 
    @first_stops = Set.new
    @trips.each.with_index do |x, col|
      trip_id = x[0] # key
      stoppings = x[1].sort_by {|stopping| stopping[:stop_sequence]} # x[1] is values
      next_grid_row = 0
      stoppings.each_with_index do |stopping, i|
        stop_id = stopping[:stop_id]
        time = format_and_flag_time stopping[:arrival_time]
        add_next_arrival(stop_id, stopping[:arrival_time], stopping[:trip_id])
        pos = stopping[:stop_sequence]
        if i == 0 && !@first_stops.include?( stopping[:stop_name] )
          @first_stops << stopping[:stop_name]
        end
        stop_row = @grid.detect {|x| x.is_a?(Hash) && x[:stop][:stop_id] == stop_id}
        if stop_row
          stop_row[:times][col] = time
          next_grid_row = @grid.index(stop_row) + 1
        else
          values = Array.new(@trips.size)
          values[col] = time
          stop_data = {
            stop_id: stop_id,
            name: stopping[:stop_name]
          }
          stop_row = {:stop => stop_data, :times => values}
          @grid.insert(next_grid_row, stop_row)
          next_grid_row += 1
        end
      end
    end
  end

  def convert_stop_data(row)
    {
      name: row[:stop_name],
      stop_integer_id: row[:stop_integer_id],
      parent_stop_mbta_id: null_or_value(row[:parent_station]),
      mbta_id: row[:stop_id],
      lat: row[:stop_lat],
      lng: row[:stop_lon],
      next_arrivals: []
    }
  end

  def ordered_stop_ids
    @grid.map {|row| row[:stop][:stop_id]}
  end

  def imminent_stop_ids
    @next_arrivals.map {|trip_id, (stop_id, time)|
      stop_id
    }
  end

  # This is for legacy client compatibility
  def use_int_keys(stops)
    @fixed_stops = {}
    stops.each {|k, v| @fixed_stops[v[:stop_integer_id].to_s] = v }
    @fixed_stops
  end

  def to_int_key(stop_id)
    @stops[stop_id][:stop_integer_id]
  end

  # use serial int stop ids instead of native ones
  def fix_grid_stop_ids
    @grid = @grid.map {|row|
      x = row[:stop][:stop_id] 
      row[:stop][:stop_id] = to_int_key x
      row
    }
  end

  def region
    lats  = @stops.map {|stop_id, data| data[:lat]}
    lngs  = @stops.map {|stop_id, data| data[:lng]}
    center_lat = lats.size > 1 ? ((lats.max + lats.min) / 2) : lats[0]
    center_lng = lngs.size > 1 ? ((lngs.max + lngs.min) / 2) : lngs[0]
    lat_span = lats.size > 1 ? ((lats.max - lats.min) * 0.95) : 0.0219
    lng_span = lngs.size > 1 ? ((lngs.max - lngs.min) * 0.9) : 0.023
    # Shift center lat up a little to compensate for height of pin
    center_lat = center_lat + (lat_span * 0.05)
    {
      center_lat: center_lat,
      center_lng: center_lng,
      lat_span: lat_span,
      lng_span: lng_span
    }
  end

  def add_next_arrival(stop_id, time, trip_id)
    return if @stops[stop_id][:next_arrivals].length >= NEXT_ARRIVALS_MAX
    time_string, in_future = *format_and_flag_time(time)
    if in_future == 1
      @stops[stop_id][:next_arrivals] << [time_string, trip_id]
      # track this for figuring out imminent stops
      if @next_arrivals[trip_id].nil?
        @next_arrivals[trip_id] = [stop_id, time]
      end
    end
  end

  def null_or_value(x)
    if x.nil? || x == ''
      nil
    else
      x
    end
  end

  private

  def format_and_flag_time(time) # time is HH:MM:SS
    return unless time
    # strip off seconds
    hour, min = *time.split(':')[0,2]
    time_string = time[/^(\d{2}:\d{2})/, 1]
    now_hour = Time.now.hour

    if now_hour < 4 # 24 hour clock, 1 am
      now_hour += + 24
    end
    time_now = "%.2d:%.2d" % [now_hour, Time.now.min]
    if time_string < time_now
      [format_time(time), -1]
    else
      [format_time(time), 1]
    end
  end

  def format_time(time)
    # "%H:%M:%S" -> 12 hour clock with am or pm
    hour, min = time.split(":")[0,2]
    hour = hour.to_i
    suffix = 'a'
    if hour > 24
      hour = hour - 24
    elsif hour == 12
      suffix = 'p'
    elsif hour == 24
      hour = 12
      suffix = 'a'
    elsif hour > 12
      hour = hour - 12
      suffix = 'p'
    elsif hour == 0
      suffix = 'a'
      hour = 12 # midnight
    end
    "#{hour}:#{min}#{suffix}"
  end

end


if __FILE__ == $0
  require 'pp'
  route = ARGV.first || 'Providence/Stoughton Line'
  direction_id = (ARGV[1] || 1).to_i
  tt = TransitTrips.new route, direction_id
  pp tt.result
end

__END__
