require 'sequel'
require 'logger'
#DB = Sequel.connect 'postgres:///mbta', :logger => Logger.new(STDOUT)
DB = Sequel.connect 'postgres:///mbta'



