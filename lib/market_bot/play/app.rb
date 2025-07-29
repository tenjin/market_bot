module MarketBot
  module Play
    class App
      attr_reader(*ATTRIBUTES)
      attr_reader :package
      attr_reader :lang
      attr_reader :result

      def self.parse(html, _opts = {})
        result = {}

        doc = Nokogiri::HTML(html, nil, 'UTF-8', &:noent)

        h2_additional_info = doc.at('h2:contains("Additional Information")')
        if h2_additional_info
          additional_info_parent         = h2_additional_info.parent.next.children.children
          node                           = additional_info_parent.at('div:contains("Updated")')
          result[:updated]               = node.children[1].text if node
          node                           = additional_info_parent.at('div:contains("Size")')
          result[:size]                  = node.children[1].text if node
          node                           = additional_info_parent.at('div:contains("Installs")')
          result[:installs]              = node.children[1].text if node
          node                           = additional_info_parent.at('div:contains("Current Version")')
          result[:current_version]       = node.children[1].text if node
          node                           = additional_info_parent.at('div:contains("Requires Android")')
          result[:requires_android]      = node.children[1].text if node
          node                           = additional_info_parent.at('div:contains("In-app Products")')
          result[:in_app_products_price] = node.children[1].text if node

          developer_div = additional_info_parent.xpath('div[./text()="Developer"]').first.parent
          developer_div ||= additional_info_parent.at('div:contains("Contact Developer")')
          if developer_div
            node = developer_div.at('a:contains("Visit website")')
            if node
              href = node.attr('href')
              encoding_options = {
                invalid: :replace,      # Replace invalid byte sequences
                undef: :replace,        # Replace anything not defined in ASCII
                replace: '',            # Use a blank for those replacements
                universal_newline: true # Always break lines with \n
              }

              href = href.encode(Encoding.find('ASCII'), encoding_options)
              href_q = URI(href).query
              if href_q
                q_param = href_q.split('&').select { |p| p =~ /q=/ }.first
                href    = q_param.gsub('q=', '') if q_param
              end
              result[:website_url] = href
            end

            result[:email] = developer_div.at('a:contains("@")').text

            node = developer_div.at('a:contains("Privacy Policy")')
            if node
              href             = node.attr('href')
              encoding_options = {
                invalid: :replace,      # Replace invalid byte sequences
                undef: :replace,        # Replace anything not defined in ASCII
                replace: '',            # Use a blank for those replacements
                universal_newline: true # Always break lines with \n
              }

              href   = href.encode(Encoding.find('ASCII'), encoding_options)
              href_q = URI(href).query
              if href_q
                q_param = href_q.split('&').select { |p| p =~ /q=/ }.first
                href    = q_param.gsub('q=', '') if q_param
              end
              result[:privacy_url] = href

              node                      = node.parent.next
              result[:physical_address] = node.text if node
            end
          end
        end
        
        if result[:installs].blank?
          # Look for install count near "Downloads"
          doc.search('*').each do |element|
            text = element.text.strip

            if text.match?(/^\d+[KMB]?\+?$/) && element.parent&.text&.downcase&.include?('download') && (element.name == 'div' && element['class'])
              result[:installs] = text
              break
            end
          end
        end

        a_genres = doc.search('a[itemprop="genre"]')
        if a_genres.blank?
          begin
            text = doc.search("//script[contains(text(),'SoftwareApplication')]").text
            data = JSON.parse(text)

            result[:categories]      = [data['applicationCategory']]
            result[:categories_urls] = ["https://play.google.com/store/apps/category/#{data['applicationCategory']}"]

            result[:content_rating] = data['contentRating']

            result[:developer]     = data.dig('author', 'name')
            result[:developer_url] = data.dig('author', 'url')
            result[:developer_id]  = result[:developer_url].split('?id=').last.strip

            result[:rating] = data.dig('aggregateRating', 'ratingValue')
            result[:votes]  = data.dig('aggregateRating', 'ratingCount').to_i

            result[:cover_image_url] = data['image']

            result[:updated] ||= text = doc.at('meta[itemprop="description"] + div + div > div:first > div[2]').text

            unless result[:current_version]
              text    = doc.search('//script[starts-with(text(),"AF_initDataCallback({key: \'ds:4\'")]').text
              l_index = text.index('AF_initDataCallback')+20
              r_index = text.rindex('}')
              hash    = text[l_index..r_index].gsub("'", '"').gsub(/(key|hash|data|sideChannel):/, "\"\\1\":")
              js_data = JSON.parse(hash)

              # this makes no sense but this is the only place to get the version number
              result[:current_version] = js_data['data'][1][2][140][0][0][0]
            end
          rescue
            # :shrug:
          end
        else
          a_genre = a_genres[0]

          result[:categories]      = a_genres.map { |d| d.text.strip }
          result[:categories_urls] = a_genres.map { |d| File.split(d['href'])[1] }

          result[:content_rating] = a_genre.parent.parent.next.text
          span_dev                = a_genre.parent.previous

          result[:developer]     = span_dev.children[0].text
          result[:developer_url] = span_dev.children[0].attr('href')
          result[:developer_id]  = result[:developer_url].split('?id=').last.strip
        end

        result[:category]     = result[:categories].first
        result[:category_url] = result[:categories_urls].first

        result[:price]          = doc.at_css('meta[itemprop="price"]')[:content] if doc.at_css('meta[itemprop="price"]')

        result[:contains_ads] = !!doc.at('div:contains("Contains Ads")')

        result[:description]  = doc.at_css('div[itemprop="description"]').inner_html.strip if doc.at_css('div[itemprop="description"]')
        result[:title]        = doc.at_css('span[itemprop="name"]').text

        if doc.at_css('meta[itemprop="ratingValue"]')
          unless result[:rating]
            node            = doc.at_css('meta[itemprop="ratingValue"]')
            result[:rating] = node[:content].strip if node
          end
          unless result[:votes]
            node            = doc.at_css('meta[itemprop="reviewCount"]')
            result[:votes]  = node[:content].strip.to_i if node
          end
        end

        a_similar = doc.at_css('a:contains("Similar")')
        if a_similar
          similar_divs     = a_similar.parent.parent.parent.next.children
          result[:similar] = similar_divs.search('a').select do |a|
            a['href'].start_with?('/store/apps/details')
          end.map do |a|
            { package: a['href'].split('?id=').last.strip }
          end.compact.uniq
        end

        begin
          h2_more = doc.at_css("h2:contains(\"#{result[:developer]}\")")
          if h2_more
            more_divs                    = h2_more.parent.next.children
            result[:more_from_developer] = more_divs.search('a').select do |a|
              a['href'].start_with?('/store/apps/details')
            end.map do |a|
              { package: a['href'].split('?id=').last.strip }
            end.compact.uniq
          end
        rescue
          # :more_from_developer is not important for our purposes; ignore any parsing errors from this block
          #
          # TODO: Maybe this gem should "fail open" when it encounters parsing errors, s.t. values returned for various
          # keys could be some class of object that indicates that a non-critical error occurred
          # (but not raise an Exception).
          result[:more_from_developer] = []
        end

        node = doc.at_css('img[alt="Cover art"]')
        unless node.nil? || result[:cover_image_url]
          result[:cover_image_url] = MarketBot::Util.fix_content_url(node[:src])
        end

        nodes = doc.search('img[alt="Screenshot Image"]', 'img[alt="Screenshot"]')
        result[:screenshot_urls] = []
        unless nodes.nil?
          result[:screenshot_urls] = nodes.map do |n|
            MarketBot::Util.fix_content_url(n[:src])
          end
        end

        node               = doc.at_css('h2:contains("What\'s New")')
        result[:whats_new] = node.inner_html if node

        result[:html] = html

        result
      end

      def initialize(package, opts = {})
        @package      = package
        @lang         = opts[:lang] || MarketBot::Play::DEFAULT_LANG
        @country      = opts[:country] || MarketBot::Play::DEFAULT_COUNTRY
        @request_opts = MarketBot::Util.build_request_opts(opts[:request_opts])
      end

      def store_url
        "https://play.google.com/store/apps/details?id=#{@package}&hl=#{@lang}&gl=#{@country}"
      end

      def update
        req = Typhoeus::Request.new(store_url, @request_opts)
        req.run
        response_handler(req.response)

        self
      end

      private

      def response_handler(response)
        if response.success?
          @result = self.class.parse(response.body)

          ATTRIBUTES.each do |a|
            attr_name  = "@#{a}"
            attr_value = @result[a]
            instance_variable_set(attr_name, attr_value)
          end
        else
          codes = "code=#{response.code}, return_code=#{response.return_code}"
          case response.code
          when 404
            raise MarketBot::NotFoundError, "Unable to find app in store: #{codes}"
          when 403
            raise MarketBot::UnavailableError, "Unavailable app (country restriction?): #{codes}"
          else
            raise MarketBot::ResponseError, "Unhandled response: #{codes}"
          end
        end
      end
    end
  end
end
