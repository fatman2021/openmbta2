require 'sinatra'
require 'json'
require 'transit_routes'
require 'transit_trips'
require 'direction'
require 'merge_realtime'

# TODO start logging analytics

get '/routes/:transport_type' do
  route_types = case params[:transport_type].downcase
  when /bus/
    [3]
  when /rail/
    [2]
  when /boat/
    [4]
  when /subway/
    [0, 1]
  end
  res = TransitRoutes.routes(route_types)
  res.to_json
end

get '/trips' do
  # irrelevant for now params[:headsign]
  route = params['route_short_name']
  direction = params['headsign']
  direction_id = Direction.name2id(direction, route) # now inbound or outbound
  puts params.inspect
  begin
    if params[:transport_type] == 'Bus'
      route = BusRoutes.find_route(route)
    end
    x = TransitTrips.new(route, direction_id)
    result = x.result
    resp = if params[:transport_type] == 'Bus' && RealtimeBus.available?(route, direction_id) 
             realtime = RealtimeBus.new(route, direction_id) 
             MergeRealtime.merge(result, realtime) 
           elsif params[:transport_type] == 'Subway' && RealtimeSubway.available?(route, direction) 
             realtime = RealtimeSubway.new(route, direction)  # use direction label
             MergeRealtime.merge(result, realtime, :subway) 
           else 
             result 
           end
    resp.to_json
  rescue TransitTrips::NoRouteData
    resp = {message: {title: 'Alert', body: 'No trips found'}}
    resp.to_json
  end
end

helpers do
  def link_to text, url
    "<a href='#{url}'>#{text}</a>"
  end

  def image_tag url
    "<img src='#{url}'/>"
  end
end

get '/help/:target_controller/:transport_type' do
  @transport_type = params[:transport_type] || "bus"
  if ['subway', 'commuter rail'].include? @transport_type.downcase
    @transport_type = @transport_type + ' train'
  end
  haml :help
end


