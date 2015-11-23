$LOAD_PATH << '.'
require 'musikbot'

module TAFIWeekly
  def self.run
    @mb = MusikBot::Session.new(inspect)

    # scheduled_article = add_new_scheduled_selection if config['add_new_scheduled_selection']
    # remove_entry_from_afi(scheduled_article) if config['remove_entry_from_afi']
    # create_schedule_page(scheduled_article) if config['prepare_scheduled_selection']

    # tag_new_tafi if config['add_tafi_to_article']
    # detag_old_tafi if config['remove_old_tafi']
    # add_former_tafi if config['add_former_tafi']

    # message_project_members if config['message_project_members']
    # notify_wikiprojects if config['notify_wikiprojects']

    add_accomplishments
  rescue => e
    @mb.report_error('Fatal error', e)
  end

  def self.add_new_scheduled_selection(throttle = 0)
    new_date = @mb.today + (4 * 7)
    start_date = new_date - 7
    page = "Wikipedia talk:Today's articles for improvement"
    old_content = @mb.get_page_props(page, rvsection: 2)
    new_content = old_content + "\n\n{{subst:TAFI scheduled selection" \
      "|week=#{new_date.cweek}|year=#{new_date.year}|date=#{start_date.strftime('%d %B %Y')}}}"

    @mb.edit(page,
      summary: 'Posting new scheduled week selection',
      content: new_content,
      section: 2,
      conflicts: true
    )

    return @mb.get(page).scan(/icon\|\w+}} \[\[(.*?)\]\].*?mbdate.*?#{@mb.today.day} #{@mb.today.strftime('%B')}/).flatten.last
  rescue MediaWiki::APIError => e
    if throttle > 3
      @mb.report_error('Edit throttle hit', e)
    elsif e.code.to_s == 'editconflict'
      add_new_scheduled_selection(throttle + 1)
    else
      raise e
    end
  end

  def self.remove_entry_from_afi(article)
    unless article
      @mb.report_error(
        'Unable to run task {{mono|remove_entry_from_afi}}, new scheduled article unknown. ' \
        'Please ensure the {{mono|add_new_scheduled_selection}} task is enabled'
      )
    end
    page = 'Wikipedia:Articles for improvement'
    old_content = @mb.get(page, rvsection: 1)
    # FIXME: check for entires with underscores instead of spaces too!
    new_content = old_content.gsub(/#.*?\[\[#{article}\]\]\s*\n/i, '') || old_content.gsub(/#.*?\[\[#{article.gsub(/ /, '_')}\]\]\s*\n/i, '')

    unless new_content
      @mb.report_error("Unable to locate [[#{article}]] within [[#{page}]]")
    end

    @mb.edit(page,
      section: 1,
      content: new_content,
      summary: "Removing [[#{article}]] as the new [[Wikipedia:Today's articles for improvement|article for improvement]]"
    )
  end

  def self.create_schedule_page(article)
    new_date = @mb.today + (4 * 7)
    page = "Wikipedia:Today's articles for improvement/#{new_date.year}/#{new_date.cweek}"
    content = "{{subst:Wikipedia:Today's articles for improvement/Schedule/Preload}}"
    @mb.edit(page, content: content)
    @mb.edit(page + '/1', content: "[[#{article}]]")
    @mb.gateway.purge("Wikipedia:Today's articles for improvement/Schedule")
    @mb.gateway.purge("Wikipedia talk:Today's articles for improvement")
  end

  def self.tag_new_tafi(throttle = 0)
    old_content = @mb.get_page_props(new_tafi, rvsection: 0)
    return nil unless old_content
    new_content = "{{TAFI}}\n" + old_content

    @mb.edit(new_tafi,
      summary: "Tagging as the current [[Wikipedia:Today's articles for improvement|article for improvement]]",
      content: new_content,
      section: 0,
      conflicts: true
    )
  rescue MediaWiki::APIError => e
    if throttle > 3
      @mb.report_error('Edit throttle hit', e)
    elsif e.code.to_s == 'editconflict'
      tag_new_tafi(article, throttle + 1)
    else
      raise e
    end
  end

  def self.detag_old_tafi(throttle = 0)
    sleep throttle * 5

    page_obj = @mb.get_page_props(old_tafi,
      rvprop: 'timestamp|content|ids|size',
      rvsection: 0,
      full_response: true
    )
    @old_tafi_new_rev = page_obj.elements['revisions'][0]
    old_content = @old_tafi_new_rev[0].to_s
    new_content = old_content.gsub(/\{\{TAFI\}\}\n*/i, '')

    if old_content.length != new_content.length
      @mb.edit(old_tafi,
        summary: "Removing {{TAFI}}, [[Wikipedia:Today's articles for improvement|article for improvement]] period has concluded",
        content: new_content,
        section: 0,
        conflicts: true
      )
    end
  rescue MediaWiki::APIError => e
    if throttle > 3
      @mb.report_error('Edit throttle hit', e)
    elsif e.code.to_s == 'editconflict'
      detag_old_tafi(throttle + 1)
    else
      raise e
    end
  end

  def self.add_former_tafi(throttle = 0)
    content = "{{Former TAFI|date=#{last_week.strftime('%e %B %Y')}|page=#{old_tafi}|oldid2=#{old_tafi_new_rev_id}"
    content += "|oldid1=#{old_tafi_old_rev_id}"

    if old_tafi_old_class != old_tafi_new_class && old_tafi_old_class.present? && old_tafi_new_class.present?
      content += "|oldclass=#{old_tafi_old_class}|newclass=#{old_tafi_new_class}"
    end
    content += '}}'

    talk_content = @mb.get_page_props("Talk:#{old_tafi}", rvsection: 0)
    @mb.edit("Talk:#{old_tafi}",
      summary: "Adding {{Former TAFI}} as previous [[Wikipedia:Today's articles for improvement|article for improvement]]",
      content: "#{talk_content}\n#{content}",
      section: 0,
      conflicts: true
    )
  rescue MediaWiki::APIError => e
    if throttle > 3
      @mb.report_error('Edit throttle hit', e)
    elsif e.code.to_s == 'editconflict'
      add_former_tafi(throttle + 1)
    else
      raise e
    end
  end

  def self.message_project_members
    spamlist = "Wikipedia:Today's articles for improvement/Members/Notifications"
    subject = "This week's [[Wikipedia:Today's articles for improvement|article for improvement]] (week #{@mb.today.cweek}, #{@mb.today.year})"
    sig = "<span style=\"font-family:sans-serif\"><b>[[User:MusikBot|<span style=\"color:black; font-style:italic\">MusikBot</span>]] <sup>[[User talk:MusikAnimal|<span style=\"color:green\">talk</span>]]</sup></b></span>"
    message = "{{subst:TAFI weekly selection notice|1=#{sig} using ~~~ on behalf of WikiProject TAFI}}"
    @mb.gateway.mass_message(spamlist, subject, message)
  end

  def self.notify_wikiprojects
    talk_text = @mb.get("Talk:#{new_tafi}",
      rvsection: 0,
      rvparse: true
    )
    wikiprojects = talk_text.scan(%r{\"\/wiki\/Wikipedia:(WikiProject_.*?)(?:#|\/|\")}).flatten.uniq - wikiproject_exclusions
    content = '{{subst:TAFI project notice}}'
    wikiprojects.each do |wikiproject|
      @mb.edit("Wikipedia talk:#{wikiproject}",
        content: content,
        section: 'new',
        summary: "Notification that [[#{new_tafi}]] has been selected as one of [[WP:TAFI|Today's articles for improvement]]"
      )
    end
  end

  def self.add_accomplishments
    editors = []
    anons = []
    bots = []
    reverts = 0

    revisions = old_tafi_revisions.to_a
    revisions.pop

    revisions.each do |revision|
      editors << revision.attributes['user']
      anons << revision.attributes['user'] if revision.attributes['anon']
      bots << revision.attributes['user'] if revision.attributes['user'] =~ /bot$/i
      reverts += 1 if revision.attributes['comment'] =~ /Reverted.*?edits?|Undid revision \d+/
    end

    entry = "{{Wikipedia:Today's articles for improvement/Accomplishments/row" \
      "|YYYY = #{@mb.today.year}" \
      "|WW = #{@mb.today.cweek}" \
      "|oldid = #{old_tafi_old_rev_id}" \
      "|olddate = #{last_week.strftime('%d %B %Y')}" \
      "|oldclass = #{old_tafi_old_class}" \
      "|newid = #{old_tafi_new_rev_id}" \
      "|newdate = #{@mb.today.strftime('%d %B %Y')}" \
      "|newclass = #{old_tafi_new_class}" \
      "|edits = #{revisions.length}" \
      "|editors = #{editors.uniq.length}" \
      "|IPs = #{anons.uniq.length}" \
      "|bots = #{bots.uniq.length}" \
      "|reverts = #{reverts}" \
      "|size_before = #{old_tafi_old_rev.attributes['size']}" \
      "|size_after = #{old_tafi_new_rev.attributes['size']}" \
      '}}'

    update_accomplishments_page(entry)
  end

  def self.update_accomplishments_page(entry, throttle = 0)
    page = "Wikipedia:Today's articles for improvement/Accomplishments"
    content = @mb.get_page_props(page)

    identifier = "&lt;!-- mb-break --&gt;\n"
    content.gsub!(/#{identifier}/, "#{entry}\n#{identifier}")

    @mb.edit(page,
      content: content,
      conflicts: true,
      summary: "Adding accomplishments for [[#{old_tafi}]]"
    )
  rescue MediaWiki::APIError => e
    if throttle > 3
      @mb.report_error('Edit throttle hit', e)
    elsif e.code.to_s == 'editconflict'
      update_accomplishments_page(entry, throttle + 1)
    else
      raise e
    end
  end

  # Helpers
  def self.old_tafi_revisions
    @old_tafi_revisions ||= @mb.gateway.custom_query(
      prop: 'revisions',
      titles: old_tafi,
      rvstartid: old_tafi_new_rev_id,
      rvendid: old_tafi_old_rev_id,
      rvprop: 'user|comment',
      rvlimit: 5000
    ).elements['pages'][0].elements['revisions']
  end

  # Old
  def self.old_tafi_old_rev
    @old_tafi_old_rev ||= @mb.get_revision_at_date(old_tafi, last_week,
      rvprop: 'ids|size',
      full_response: true
    ).elements['revisions'][0]
  end

  def self.old_tafi_old_rev_id
    @old_tafi_old_rev_id ||= old_tafi_old_rev.attributes['revid']
  end

  def self.old_tafi_old_class
    return @old_tafi_old_class if @old_tafi_old_class
    unless old_talk_text = @mb.get_revision_at_date("Talk:#{old_tafi}", last_week, rvsection: 0)
      @mb.report_error("Unable to fetch [[Talk:#{old_tafi}]], aborting add_former_tafi") and return nil
    end
    @old_tafi_old_class = get_article_class(old_talk_text)
  end

  # New
  def self.old_tafi_new_rev
    @old_tafi_new_rev ||= @mb.get_page_props(old_tafi,
      rvprop: 'ids|size',
      full_response: true
    ).elements['revisions'][0]
  end

  def self.old_tafi_new_rev_id
    @old_tafi_new_rev_id ||= old_tafi_new_rev.attributes['revid']
  end

  def self.old_tafi_new_class
    return @old_tafi_new_class if @old_tafi_new_class
    new_talk_text = @mb.get_page_props("Talk:#{old_tafi}", rvsection: 0)
    @old_tafi_new_class = get_article_class(new_talk_text)
  end

  def self.old_tafi
    return @old_tafi if @old_tafi
    old_tafi_page_name = "Wikipedia:Today's articles for improvement/#{last_week.year}/#{last_week.cweek}/1"
    @old_tafi = @mb.get(old_tafi_page_name).scan(/\[\[(.*)\]\]/).flatten[0]
  end

  def self.new_tafi
    @new_tafi ||= @mb.get("Wikipedia:Today's articles for improvement/#{@mb.today.year}/#{@mb.today.cweek}/1").scan(/\[\[(.*)\]\]/).flatten[0]
  end

  def self.get_article_class(text)
    text.scan(/\|class\s*=\s*(\w+)\s*(?:\||})/).flatten.first || 'Unassessed'
  end

  def self.wikiproject_exclusions
    [
      'WikiProject_Deletion_sorting',
      'WikiProject_Guild_of_Copy_Editors'
    ]
  end

  def self.last_week
    @mb.today - 7
  end

  # API-related
  def self.config
    @config ||= JSON.parse(CGI.unescapeHTML(@mb.get('User:MusikBot/TAFIWeekly/config.js')))
  end
end

TAFIWeekly.run
