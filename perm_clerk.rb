# TODO: have the bot update User:MusikBot/task_1 with 'true' unless the task doesn't finish, in which case it will write 'false'
#       Then on User:MusikBot in the lists of tasks it will transclude the page into a parser function showing whether or not the task is running and when it failed

module PermClerk
  require 'date'
  require 'pry'
  require 'logger'

  @logger = Logger.new("perm_clerk.log")
  @logger.level = Logger::INFO

  EDIT_THROTTLE = 3
  PERMISSION = "Rollback"
  SEARCH_DAYS = 30
  SPLIT_KEY = "====[[User:"
  PERMISSIONS = [
    # "Account creator",
    # "Autopatrolled",
    # "Confirmed",
    # "File mover",
    # "Pending changes reviewer",
    # "Reviewer",
    "Rollback"
    # "Template editor"
  ]

  @usersCache = {}

  def self.init(mw)
    @mw = mw
    @baseTimestamp = nil
    @pageName = "Wikipedia:Requests for permissions/#{PERMISSION}"
    @startTimestamp = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    @usersCount = 0

    for @permission in PERMISSIONS
      # TODO: check if task is set to run for this permission
      @editThrottle = 0
      unless process(@permission)
        error("Failed to process")
      else
        info("Processing of #{@permission} complete")
      end
    end
  end

  def self.editPage(newWikitext)
    if @editThrottle < 3
      sleep @editThrottle
      @editThrottle += 1

      info("Writing to page, attempt #{@editThrottle}")

      # attempt to save
      begin
        @mw.edit(@pageName, newWikitext, {
          basetimestamp: @baseTimestamp,
          # bot: true,
          contentformat: 'text/x-wiki',
          section: 1,
          starttimestamp: @startTimestamp,
          summary: "Bot clerking, #{@usersCount} user#{'s' if @usersCount > 1} with previously declined requests",
          text: newWikitext
        })
      rescue MediaWiki::APIError => e
        if e.code.to_s == "editconflict"
          warn("Edit conflict, trying again")
          return process(@permission)
        else
          warn("API error when writing to page: #{e.code.to_s}, trying again")
          return process(@permission)
        end
      rescue Exception => e
        error("Unknown exception when writing to page: #{e.message}") and return false
      end
    else
      error("Throttle hit for edit page operation, continuing to process next permission") and return false
    end

    true
  end

  def self.findLinks(userName)
    if @usersCache[userName]
      info("Cache hit for #{userName}")
      return @usersCache[userName]
    end

    currentDate = Date.today
    targetDate = currentDate - SEARCH_DAYS
    links = []

    for monthIndex in (targetDate.month..currentDate.month)
      monthName = Date::MONTHNAMES[monthIndex]
      info("Checking month #{monthName} for #{userName}")
      page = @mw.get("Wikipedia:Requests for permissions/Denied/#{monthName} #{Date.today.year}")
      # FIXME: (1) use match instead of scan (2) make sure the date itself is within range
      matches = page.scan(/{{Usercheck.*#{userName}.*\/#{PERMISSION}\]\].*(http:\/\/.*)\s+link\]/)
      links += matches.flatten if matches
    end

    return @usersCache[userName] = links
  end

  def self.newSectionWikitext(section, links)
    linksMessage = links.map{|l| "[#{l}]"}.join
    comment = "\n:{{comment|Automated comment}} This user has had #{links.length} request#{'s' if links.length > 1} for #{PERMISSION.downcase} declined in the past #{SEARCH_DAYS} days (#{linksMessage}). ~~~~\n"
    return SPLIT_KEY + section.gsub(/\n+$/,"") + comment
  end

  def self.process(permission)
    info("Processing...")
    newWikitext = []
    @fetchThrotte = 0

    oldWikitext = setPageProps
    return false unless oldWikitext

    sections = oldWikitext.split(SPLIT_KEY)

    binding.pry

    sections.each do |section|
      debug("Checking section: #{section}")
      links = []
      if userNameMatch = section.match(/{{(?:template\:)?rfplinks\|1=(.*)}}/i)
        userName = userNameMatch.captures[0]

        if section.match(/{{(?:template\:)?(done|not done|already done)}}/i) || section.match(/:{{comment|Automated comment}}.*MusikBot/)
          info("#{userName}'s request already responded to or MusikBot has already commented")
          newWikitext << SPLIT_KEY + section
        else
          info("Searching #{userName}")

          links += findLinks(userName) rescue []
          if links.length > 0
            info("#{links.length} links found for #{userName}")
            newWikitext << newSectionWikitext(section, links)
            @usersCount += 1
          else
            info("no links found for #{userName}")
            newWikitext << SPLIT_KEY + section
          end
        end
      else
        newWikitext << section
      end
    end

    return editPage(CGI.unescapeHTML(newWikitext.join))
  end

  def self.setPageProps
    if @fetchThrotte < 3
      info("Fetching page properties, attempt #{@fetchThrotte}")
      sleep @fetchThrotte
      @fetchThrotte += 1
      begin
        pageObj = @mw.custom_query(prop: 'info|revisions', titles: @pageName, rvprop: 'timestamp|content')[0][0]
        @baseTimestamp = pageObj.attributes['touched']
        return pageObj.elements['revisions'][0][0].to_s
      rescue
        warn("Unable to fetch page properties, trying again")
        return setPageProps
      end
    else
      error("Unable to fetch page properties, continuing to process next permission") and return false
    end

    true
  end

  def self.debug(msg); @logger.debug("#{@permission.upcase} : #{msg}"); end
  def self.info(msg); @logger.info("#{@permission.upcase} : #{msg}"); end
  def self.warn(msg); @logger.warn("#{@permission.upcase} : #{msg}"); end
  def self.error(msg); @logger.error("#{@permission.upcase} : #{msg}"); end
end