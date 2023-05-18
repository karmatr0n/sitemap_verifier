#!/usr/bin/env ruby
# frozen_string_literal: true

require 'uri'
require 'net/http'
require 'nokogiri'
require 'json'
require 'async'
require 'debug'

module HttpHelper
  USER_AGENTS = [
    'Mozilla/5.0 (X11; Linux x86_64; rv:60.0) Gecko/20100101 Firefox/81.0',
    'Mozilla/5.0 (compatible; MSIE 10.0.0; Windows Phone OS 8.0.0; Trident/6.0.0; IEMobile/10.0.0; Lumia 630',
    'Mozilla/5.0 (iPad; CPU OS 6_0_1 like Mac OS X) AppleWebKit/536.26 (KHTML, like Gecko) Version/6.0 Mobile/10A523 Safari/8536.25'
  ].freeze

  def http_get_request(path)
    request = Net::HTTP::Get.new(path)
    request['User-Agent'] = user_agent
    request
  end

  def user_agent
    USER_AGENTS.sample
  end

  def http_request(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE if http.use_ssl?
    http
  end
end

class SiteMapper
  include HttpHelper
  attr_reader :uri

  def initialize(url)
    @uri = URI.parse(url)
  end

  def map_urls
    retries ||= 0
    http = http_request(@uri)
    response = http.request(http_get_request(@uri.path))
    response.code == '200' ? urls_from_xml(response.body) : []
  rescue Net::OpenTimeout, OpenSSL::SSL::SSLError => _e
    (retries += 1) <= 2 ? retry : []
  end

  def urls_from_xml(xml)
    doc = Nokogiri::XML(xml)
    doc.xpath('//xmlns:loc').map(&:text)
  end
end

class URLChecker
  include HttpHelper
  attr_reader :status_code, :uri, :url_verified

  def initialize(url)
    @uri = URI.parse(url)
    @status_code = nil
    @start_time = Time.now
    @url_verified = false
  end

  def verify_status
    retries ||= 0
    http = http_request(@uri)
    response = http.request(http_get_request(@uri.path))
    @end_time = Time.now
    @url_verified = true
    @status_code = response.code
  rescue Net::OpenTimeout, OpenSSL::SSL::SSLError => _e
    retry if (retries += 1) <= 2
  end

  def stats
    {
      url: @uri.to_s,
      status_code: @status_code,
      start_time: @start_time,
      end_time: @end_time,
      duration: @end_time.to_f - @start_time.to_f,
      url_verified: @url_verified
    }
  end
end

class SitemapVerifier
  attr_reader :stats, :debug, :max_async_requests

  def initialize(sitemap_url, debug: false, max_async_requests: 30)
    @site_mapper = SiteMapper.new(sitemap_url)
    @stats = []
    @debug = debug
    @max_async_requests = max_async_requests
    @output_filename = nil
  end

  def verify_urls
    all_urls = map_urls
    all_urls_size = all_urls.size
    max_requests = all_urls_size.positive? && all_urls_size < max_async_requests ? all_urls_size : max_async_requests
    all_urls.each_cons(max_requests).each do |urls|
      async_scan_urls(urls)
    end
  end

  def map_urls
    @site_mapper.map_urls.map do |child_url|
      puts("Getting urls from: #{child_url}") if debug
      child_map = SiteMapper.new(child_url)
      child_map.map_urls
    end.flatten
  end

  def async_scan_urls(urls)
    Async do
      urls.each do |url|
        Async do
          url_checker = URLChecker.new(url)
          url_checker.verify_status
          puts(url_checker.stats) if debug
          stats.push(url_checker.stats)
        end
      end
    end
  end

  def save_json(filename = output_filename)
    file = File.new(filename, 'w')
    file.puts(JSON.pretty_generate(stats))
    file.close
  end

  def output_filename
    @output_filename ||= "#{@site_mapper.uri.host}_#{Time.now.to_i}.json"
  end
end

if ARGV.length == 1 && $PROGRAM_NAME == __FILE__
  sitemap_verifier = SitemapVerifier.new(ARGV.shift, debug: true)
  sitemap_verifier.verify_urls
  sitemap_verifier.save_json
  puts(sitemap_verifier.output_filename)
else
  puts "Usage: ruby #{__FILE__} <sitemap_url>"
end
