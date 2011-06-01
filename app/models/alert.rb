require 'open-uri'
require 'openmbta2'

class Alert
  FEED_URL = "http://talerts.com/rssfeed/alertsrss.aspx"

  def self.update
    puts "Updating t-alerts at #{Time.now}"
    items = parse(open(FEED_URL).read)
    items.each do |item_hash|
      DB[:t_alerts].filter(:guid => item_hash[:guid]).delete
      DB[:t_alerts].insert item_hash
    end
  end

  def self.parse(xml)
    doc = Nokogiri::XML.parse(xml)
    items = doc.xpath("//item").map do |item|
      %w{title description link guid pubDate}.inject({}) do |memo, x|
        memo[(x == 'pubDate' ? :pubdate : x.to_sym)] = item.at(x).inner_text
        memo
      end
    end
    items
  end
end

if __FILE__ == $0
  Alert.update
end
