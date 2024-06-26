require 'database'
require 'nokogiri'
require 'open-uri'

# This module contains scripts that populate the real-time data tables for MBTA buses.
# Another module should inject this data into the trip data returned to the mobile client.

module NextbusFeeds

  PING_INTERVAL = 0.1

  class << self
    def populate_route_list
      url = 'http://webservices.nextbus.com/service/publicXMLFeed?command=routeList&a=mbta'
      puts `curl -I '#{url}'`
      xml = `curl -sL '#{url}'`
      puts xml
      Nokogiri::XML.parse(xml).search("route").each do |r|
        params = {
          tag: r[:tag],
          title: r[:title]
        }
        unless DB[:nextbus_routes].first(params)
          puts params.inspect
          DB[:nextbus_routes].insert params
        end
      end
    end

    def populate_route_configs
      DB[:nextbus_route_configs].delete
      DB[:nextbus_routes].all.each do |route|
        get_route_config route[:tag]
      end
    end

    def get_route_config(route_tag)
      url = "http://webservices.nextbus.com/service/publicXMLFeed?command=routeConfig&a=mbta&r=#{route_tag}"
      raw = `curl -sL '#{url}'`
      xml = Nokogiri::XML.parse raw
      DB["delete from nextbus_route_configs where routetag = ?", route_tag]
      xml.search("route").each do |route|
        route[:tag]
        route.xpath("stop").each do |stop|
          params = {
            routetag: route_tag,
            stoptag: stop[:tag],
            stoptitle: stop[:title]
          }
          unless DB[:nextbus_route_configs].first(params)
            puts params.inspect
            DB[:nextbus_route_configs].insert params
          end
        end
      end
    end

    def get_all_predictions
      puts "Getting all predictions -- #{Time.now}"
      DB["select tag from nextbus_routes"].each do |x|
        puts "Getting predictions for route #{x[:tag]} -- #{Time.now}"
        get_predictions x[:tag]
        sleep PING_INTERVAL
      end
    end

    def get_predictions(route_tag)
      url = 'http://webservices.nextbus.com/service/publicXMLFeed?command=predictionsForMultiStops&a=mbta'
      params = get_stop_tags(route_tag).map {|stoptag| "stops=#{route_tag}|null|#{stoptag}"}.join('&')
      url += "&" + params
      xml = `curl -s '#{url}'` # open-uri doesn't work on this long url
      DB.run("delete from nextbus_predictions where routetag = '#{route_tag}'")
      Nokogiri::XML.parse(xml).xpath('//predictions').each do |s|
        stop_tag = s[:stopTag] 
        s.xpath('./direction/prediction').each do |p|
          params = {
            routetag: route_tag,
            stoptag: stop_tag,
            dirtag: p[:dirTag],
            arrival_time: Time.at(p[:epochTime].to_i / 1000),
            vehicle: p[:vehicle],
            block: p[:block],
            triptag: p[:tripTag]
          }
          DB[:nextbus_predictions].insert params
        end
      end
    end

    def get_stop_tags(route_tag)
      res = DB["select stoptag from nextbus_route_configs where routetag = ?", route_tag].map {|s| s[:stoptag]}
      if res.empty?
        raise "No stop tags found for route tag #{route_tag}"
      end
      res
    end
  end
end


if __FILE__ == $0
  #NextbusFeeds.populate_route_list
  #NextbusFeeds.populate_route_configs
  #NextbusFeeds.get_predictions("4")
  loop do
    NextbusFeeds.get_all_predictions
  end
end

