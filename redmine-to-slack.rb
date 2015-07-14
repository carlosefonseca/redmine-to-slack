#!/usr/bin/env ruby

require 'rest-client'
require 'cgi'

# Simple key value store.
# Implemented on top of Active Record. Tested on Postgres DB. Should work with other engines, as long as you specify a correct spec.
# Table is created on initialization, if it doesn't exist.
class KeyValueStore
  require 'active_record'

  # Internal class that contains the fields 'key' and 'value'
  class KeyValue < ActiveRecord::Base
  end


  def initialize(spec)
    ActiveRecord::Base.establish_connection(spec)
    unless KeyValue.table_exists?
      ActiveRecord::Schema.define do
        create_table :key_values do |table|
          table.column :key, :string
          table.column :value, :string
        end
      end
    end
  end

  # Store a value associated with a key. If the key already exists, replaces the value.
  def put(key, value)
    obj = KeyValue.find_by_key(key)
    if obj
      KeyValue.update(obj.id, :value=>value)
    else
      KeyValue.create(:key=>key, :value=>value)
    end
  end

  # Returns the value associated with the key, or nil if the key doesn't exist.
  def get(key, default=nil)
    find = KeyValue.find_by_key(key)
    find ? find.value : default
  end
end

################################################################################

module RedmineSlack

  # Communicates with the Redmine API
  class RedmineAPI
    attr_accessor :base_url, :api_key, :restclient, :verbose

    REDMINE_AUTH_HEADER='X-Redmine-API-Key'

    def get(url)
      return self.restclient[url].get
    end

    def initialize(base_url, api_key, verbose:verbose)
      self.base_url = base_url
      self.api_key = api_key
      self.verbose = verbose

      self.restclient = RestClient::Resource.new(base_url, :headers => { REDMINE_AUTH_HEADER => self.api_key, :accept => :json, :content_type => :json }) { |response, request, result, &block|
        case response.code
        when 200
          JSON.parse(response)
        else
          puts response.request.url
          puts JSON.parse(response)
          response.return!(request, result, &block)
        end
      }
    end

    # Requests issues. Returns parsed objects.
    # format: http://www.redmine.org/projects/redmine/wiki/Rest_Issues
    def issues(created_on: nil, limit: 100, project:nil, status:nil, sort:nil)
      x = {}
      x[:created_on] = created_on if created_on
      x[:limit] = limit if limit
      x[:project_id] = project if project
      x[:status] = status if status
      x[:sort] = sort if sort
      qs = x.empty? ? "" : x.reduce("?") { |s,(k,v)| s+="#{k}=#{CGI.escape(v.to_s)}&" }
      return get("issues.json"+qs)
    end
  end

  ################################################################################

  # The Glue.
  # Requests Redmine issues and pipes them to Slack
  class RedmineSlackGlue
    @last_creation_k = "last_creation"
    REDMINE_ICON_URL='https://cld.pt/dl/download/a16a4a48-1222-4ddd-abb1-e8d69b989ad9/redmine_fluid_icon.png'
    attr_accessor :verbose

    def initialize(redmine_api, slack_api, kv, verbose:verbose)
      @redmine_api = redmine_api
      @slack_api = slack_api
      @kv = kv
      self.verbose = verbose
    end

    def issue_url(id)
      @redmine_api.base_url+'issues/'+id.to_s
    end

    # Fetches new issues from Redmine. Requests with a creation date above the last issue received
    def fetch_issues()

      # fetch last created date
      last_creation = @kv.get(@last_creation_k) # || "2015-05-11T16:37:21Z"

      # request Redmine issues
      issues = @redmine_api.issues(created_on: ">=#{last_creation}", limit:200, sort:"created_on")['issues']
      puts issues if self.verbose
      
      # filter issues to include only certain projects, avoid certain users, avoid self tickets
      issues = issues.select do |issue|
        Utils.project_whitelisted? issue and Utils.user_not_blacklisted? issue and not Utils.ticket_to_self? issue
      end

      # no issues
      if issues.empty?
        puts "#{Utils.human_timestamp} No new issues since #{last_creation}."
        return
      end

      # post issues
      issues.each do |issue|
        post_issue(issue)
      end

      # store the created data of the last ticket + 1 second
      last_creation = issues.last["created_on"]
      last_creation_plus = (Time.parse(last_creation)+1).iso8601
      @kv.put(@last_creation_k, last_creation_plus)
      
      puts "#{Utils.human_timestamp}: Posted #{issues.length} issues. Last created #{@kv.get(@last_creation_k)}"

    end

    # converts redmine issues in slack messages (and posts them)
    def post_issue(issue)
      proj = issue["project"]["name"]
      cat = issue["category"] ? issue["category"]["name"] : nil
      id = issue["id"]
      subject = issue["subject"]
      description = issue["description"]
      author = issue["author"]["name"]
      # author_slack = Utils.convert_redmine_name_to_slack author
      assigned_to = issue["assigned_to"] ? issue["assigned_to"]["name"] : :not_assigned
      assigned_to_slack = Utils.convert_redmine_name_to_slack assigned_to
      tracker = issue["tracker"]["name"]
      url = SlackAPI.url(issue_url(id), "##{id}")
      # updated = issue["updated_on"]
      created = issue["created_on"]

      description = RedmineSlackGlue.convert_textile_to_markdown(description.gsub(/\n\n/,"\n"))
      color = RedmineSlackGlue.priority_to_color(issue["priority"]["id"])

      puts "#{issue["priority"]["id"]} #{created} #{proj} ##{id} #{cat} #{subject}" if self.verbose

      cat = RedmineSlackGlue.convert_category(cat)

      @slack_api.post({
        :channel => "##{proj.downcase}",
        :text => "#{assigned_to_slack}: Ticket #{url} *#{subject}* - #{tracker}#{cat}",
        :attachments => [{
         :fallback => RedmineSlackGlue.clean_markup(description),
         :color => color,
         :text => description,
         :mrkdwn_in=> ["text"]
         }],
         :username => "#{author}",
         :icon_url => REDMINE_ICON_URL
         })
    end

    # converts Redmine priorities to Slack colors
    def self.priority_to_color(priority_id)
      if priority_id == 1
        nil
      elsif priority_id == 2
        "#D7D7D7"
      elsif priority_id == 3
        "warning"
      elsif priority_id >= 4
        "danger"
      end
    end

    # some format conversion from textile to markdown
    def self.convert_textile_to_markdown(text)
      # @inline block@ => `inline block`
      text.gsub(/\s@(.*?)@\s/, ' `\1` ') \
        # <pre>block</pre> => ```block```
        .gsub(/<pre>(.*?)<\/pre>/, ' ```\1``` ')
    end

    # remove textile markup for fallback text
    # not really tested if this is the best approach 
    def self.clean_markup(text)
      text.gsub(/\s@(.*?)@\s/, ' \1 ') \
        .gsub(/\s\*(.*?)\*\s/, ' \1 ') \
        .gsub(/\s_(.*?)_\s/, ' \1 ') \
        .gsub(/\s<pre>(.*?)<\/pre>\s/, ' \1 ')
    end

    # Converts category names to emoji. Just put them on this hash
    @cat_emoji = {"Android"=>":android:", "iOS"=>":aapl:"}
    def self.convert_category(cat)
      if cat
        if @cat_emoji.include? cat
          cat = @cat_emoji[cat]
        else
          cat = cat ? "/#{cat}" : ""
        end
      end
    end

    def post_hello
      #@slack_api.post({:channel=>"@carlos.fonseca",:text=>"Hello! Last creation: #{@kv.get(@last_creation_k)}",:username=>"Redmine2Slack",:icon_url => REDMINE_ICON_URL})
    end

    def post_goodbye
      #@slack_api.post({:channel=>"@carlos.fonseca",:text=>"Bye! Last creation: #{@kv.get(@last_creation_k)}",:username=>"Redmine2Slack",:icon_url => REDMINE_ICON_URL})
    end
  end

  ################################################################################

  # Communicates with Slack
  class SlackAPI
    attr_accessor :url, :channel_override, :enabled, :verbose

    def initialize(url, verbose:false)
      self.url = url
      self.enabled = true
      self.verbose = verbose
    end

    def post(data)
      if enabled
        data["link_names"]=1
        data[:channel] = self.channel_override if self.channel_override
        if self.verbose
          puts
          puts "NEW SLACK POST\n#{data.to_json}"
          puts
        end
        RestClient.post self.url, data.to_json
        sleep 1 # avoid bursts to keep Slack happy
      else
        if self.verbose
          puts
          puts "NEW SLACK WOULD-BE POST\n#{data.to_json}"
          puts
        else            
          puts "NEW SLACK WOULD-BE POST: #{data[:text]}"
        end
      end
    end

    def test()
      RestClient.post self.url, {:text=>"this is a test!", :channel=>'@carlos.fonseca'}.to_json
    end

    def self.url(url, title=nil)
      "<#{url}" + (title ? "|#{title}>" : ">")
    end

    def self.blockquote(text)
      ">"+text.gsub(/\n/, "\n>")
    end

    def self.truncate(text, length:30)
      text.length > length ? text[0..length].gsub(/\s\w*\Z/,'...') : text
    end
  end


  ################################################################################

  # Some utility stuff... some should REALLY be converted to be configuration but I'm kinda lazy right now.
  # Hopefully sometime in the near future.

  class Utils
    # converts "First Last" to @first.last, handles special cases and when name is :not_assigned
    # (TODO: this mapping should come from a configuration)
    def self.convert_redmine_name_to_slack(name)
      return "_Not Assigned_" if name == :not_assigned
      I18n.enforce_available_locales = false
      special_cases = {
        "Liliana Monteiro" => "@liliana",
        "Nelson Silva" => "@nelson"
      }
      return special_cases[name] || '@'+I18n.transliterate(name.downcase).gsub(/ /, ".")
    end

    # is author the same as assigned to?
    def self.ticket_to_self?(issue)
      issue["assigned_to"] ? issue["author"]["id"] == issue["assigned_to"]["id"] : false
    end

    # What projects are allowed to post issues
    # (TODO: this list should come from a configuration)
    @@project_whitelist = ["xtourmaker", "mysight", "gourmetbus", "mymuseum"]
    def self.project_whitelisted?(issue)
      @@project_whitelist.include? issue["project"]["name"].downcase
    end

    # If issue involves a certain user, don't post
    # (TODO: this list should come from a configuration)
    @@user_blacklist = ['ricardo.ferreira', 'pedro.morais']
    def self.user_not_blacklisted?(issue)
      @@user_blacklist.include? issue["assigned_to"]["name"] or @@user_blacklist.include? issue["author"]["name"]
      # true
    end

    # returns a timestamp in pt-PT time
    def self.human_timestamp()
      Time.now.getlocal("+01:00").to_s
    end
  end
end


# Trap `Kill`, ^C, SIGTERM (also for heroku)
# Saves the kill termination request for when the app sees a good time for that
@exit = false
Signal.trap("TERM") {
  puts "#{RedmineSlack::Utils.human_timestamp} Requesting shut down..."
  @exit = true
}


# Checks if the required environment vars are set, and exits with a warning if some aren't.
def check_vars
  req_env_vars = ['REDMINE_BASE_URL', 'REDMINE_API_KEY', 'SLACK_WEBHOOK_URL', 'DATABASE_URL']
  missing_env_vars = req_env_vars - ENV.keys
  unless missing_env_vars.empty?
    puts "The following environment variables are required: #{missing_env_vars.join ', '}"
    exit
  end
end

# Constructs the objects using the environment variables.
# Returns an instance of RedmineSlack::RedmineSlackGlue ready to be used.
def setup
  redmine_base_url=ENV['REDMINE_BASE_URL']
  redmine_api_key=ENV['REDMINE_API_KEY']
  slack_webhook_url=ENV['SLACK_WEBHOOK_URL']
  verbose = ENV['VERBOSE'] == '1'
  slack_off = ENV['SLACK_OFF'] == '1'

  kv = KeyValueStore.new(ENV["DATABASE_URL"])
  rAPI = RedmineSlack::RedmineAPI.new(redmine_base_url, redmine_api_key, verbose:verbose)
  slack_api = RedmineSlack::SlackAPI.new(slack_webhook_url, verbose:verbose)
  slack_api.channel_override = ENV['SLACK_CHANNEL_OVERRIDE']
  slack_api.enabled = !slack_off

  RedmineSlack::RedmineSlackGlue.new(rAPI, slack_api, kv, verbose:verbose)
end

def check_exit
  if @exit
    yield if block_given?
    puts "#{RedmineSlack::Utils.human_timestamp} bye..."
    exit
  end  
end

if __FILE__ == $0
  $stdout.sync = true # enables heroku real time logging

  # env vars set?
  check_vars

  # make instance of RedmineSlack::RedmineSlackGlue
  glue = setup

  # Post on Slack
  glue.post_hello
  loop do
    # the cool stuff
    glue.fetch_issues()

    # sleeps 6s, 10 times (~1min total). Checks if someone wants it dead in between.
    (0..10).each do
      check_exit { glue.post_goodbye }

      sleep 6

      check_exit { glue.post_goodbye }
    end
  end
end
