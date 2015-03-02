#
# Author:: Adam Jacob (<adam@opscode.com>)
# Copyright:: Copyright (c) 2009 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/knife'
require 'chef/knife/core/node_presenter'

class Chef
  class Knife
    class Search < Knife

      include Knife::Core::MultiAttributeReturnOption

      deps do
        require 'chef/node'
        require 'chef/environment'
        require 'chef/api_client'
        require 'chef/search/query'
      end

      include Knife::Core::NodeFormattingOptions

      banner "knife search INDEX QUERY (options)"

      option :sort,
        :short => "-o SORT",
        :long => "--sort SORT",
        :description => "The order to sort the results in",
        :default => nil

      option :start,
        :short => "-b ROW",
        :long => "--start ROW",
        :description => "The row to start returning results at",
        :default => 0,
        :proc => lambda { |i| i.to_i }

      option :rows,
        :short => "-R INT",
        :long => "--rows INT",
        :description => "The number of rows to return",
        :default => nil,
        :proc => lambda { |i| i.to_i }

      option :run_list,
        :short => "-r",
        :long => "--run-list",
        :description => "Show only the run list"

      option :id_only,
        :short => "-i",
        :long => "--id-only",
        :description => "Show only the ID of matching objects"

      option :query,
        :short => "-q QUERY",
        :long => "--query QUERY",
        :description => "The search query; useful to protect queries starting with -"

      option :filter_result,
        :short => "-f FILTER",
        :long => "--filter-result FILTER",
        :description => "Only bring back specific attributes of the matching objects; for example: \"ServerName=name, Kernel=kernel.version\""

      def run
        read_cli_args
        fuzzify_query

        if @type == 'node'
          ui.use_presenter Knife::Core::NodePresenter
        end

        q = Chef::Search::Query.new
        escaped_query = URI.escape(@query,
                           Regexp.new("[^#{URI::PATTERN::UNRESERVED}]"))

        result_items = []
        result_count = 0

        search_args = Hash.new
        search_args[:sort] = config[:sort] if config[:sort]
        search_args[:start] = config[:start] if config[:start]
        search_args[:rows] = config[:rows] if config[:rows]
        if config[:filter_result]
          search_args[:filter_result] = create_result_filter(config[:filter_result])
        elsif (not ui.config[:attribute].nil?) && (not ui.config[:attribute].empty?)
          search_args[:filter_result] = create_result_filter_from_attributes(ui.config[:attribute])
        end

        begin
          q.search(@type, escaped_query, search_args) do |item|
            formatted_item = Hash.new
            if item.is_a?(Hash)
              # doing a little magic here to set the correct name
              formatted_item[item["data"]["__display_name"]] = item["data"]
              formatted_item[item["data"]["__display_name"]].delete("__display_name")
            else
              formatted_item = format_for_display(item)
            end
            result_items << formatted_item
            result_count += 1
          end
        rescue Net::HTTPServerException => e
          msg = Chef::JSONCompat.from_json(e.response.body)["error"].first
          ui.error("knife search failed: #{msg}")
          exit 1
        end

        if ui.interchange?
          output({:results => result_count, :rows => result_items})
        else
          ui.log "#{result_count} items found"
          ui.log("\n")
          result_items.each do |item|
            output(item)
            unless config[:id_only]
              ui.msg("\n")
            end
          end
        end
      end

      def read_cli_args
        if config[:query]
          if @name_args[1]
            ui.error "please specify query as an argument or an option via -q, not both"
            ui.msg opt_parser
            exit 1
          end
          @type = name_args[0]
          @query = config[:query]
        else
          case name_args.size
          when 0
            ui.error "no query specified"
            ui.msg opt_parser
            exit 1
          when 1
            @type = "node"
            @query = name_args[0]
          when 2
            @type = name_args[0]
            @query = name_args[1]
          end
        end
      end

      def fuzzify_query
        if @query !~ /:/
          @query = "tags:*#{@query}* OR roles:*#{@query}* OR fqdn:*#{@query}* OR addresses:*#{@query}*"
        end
      end

      # This method turns a set of key value pairs in a string into the appropriate data structure that the
      # chef-server search api is expecting.
      # expected input is in the form of:
      # -f "return_var1=path.to.attribute, return_var2=shorter.path"
      #
      # a more concrete example might be:
      # -f "env=chef_environment, ruby_platform=languages.ruby.platform"
      #
      # The end result is a hash where the key is a symbol in the hash (the return variable)
      # and the path is an array with the path elements as strings (in order)
      # See lib/chef/search/query.rb for more examples of this.
      def create_result_filter(filter_string)
        final_filter = Hash.new
        filter_string.gsub!(" ", "")
        filters = filter_string.split(",")
        filters.each do |f|
          return_id, attr_path = f.split("=")
          final_filter[return_id.to_sym] = attr_path.split(".")
        end
        return final_filter
      end

      def create_result_filter_from_attributes(filter_array)
        final_filter = Hash.new
        filter_array.each do |f|
          final_filter[f] = f.split(".")
        end
        # adding magic filter so we can actually pull the name as before
        final_filter["__display_name"] = [ "name" ]
        return final_filter
      end

    end
  end
end
