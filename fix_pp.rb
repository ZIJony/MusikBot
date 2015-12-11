$LOAD_PATH << '.'
require 'musikbot'

CATEGORY = 'Category:Wikipedia pages with incorrect protection templates'

module FixPP
  def self.run
    # FIXME: remember to remove 'true' so it will go by /Run
    @mb = MusikBot::Session.new(inspect, true)

    pages = category_members

    pages.each do |page|
      page_obj = protect_info(page).first

      # don't try endlessly to fix the same page
      if @mb.env == :production && @mb.parse_date(page_obj.attributes['touched']) > cache_touched(page_obj, :get)
        STDOUT.puts "cache hit for #{page_obj.attributes['title']}"
      elsif page_obj.elements['revisions'][0].attributes['user'] == 'MusikBot'
        STDOUT.puts 'MusikBot was last to edit page'
      else
        process_page(page_obj)
      end
    end
  rescue => e
    @mb.report_error('Fatal error', e)
  end

  def self.process_page(page_obj, throttle = 0)
    @page_obj = page_obj
    @title = @page_obj.attributes['title']
    @content = @mb.get_page_props(@title)
    # FIXME: make as an array of hashes, with :type such as :unprotected or :invalid
    #   so that we can consolidate similar edit summaries
    @edit_summaries = []
    @is_template = @page_obj.attributes['ns'].to_i == 10
    @is_talk_page = @page_obj.attributes['ns'].to_i.odd?

    new_pps = repair_existing_pps
    remove_pps

    if new_pps.present?
      if @is_template
        @content = noinclude_pp(new_pps)
      else
        @content = new_pps + "\n" + @content
      end
    end

    # FIXME: won't need this if we get rid of <include> around template in noinclude_pp()
    # @content.sub!(/\A\<noinclude\>\s*\<\/noinclude\>/, '') if @is_template

    # if nothing changed, cache page title and touched time into redis
    return cache_touched(@page_obj, :set) unless @edit_summaries.present?

    @mb.edit(@title,
      content: @content,
      conflicts: true,
      summary: @edit_summaries.uniq.join(', '),
      minor: true
    )
  rescue MediaWiki::APIError => e
    if throttle > 3
      @mb.report_error('Edit throttle hit', e)
    elsif e.code.to_s == 'editconflict'
      process_page(@page_obj, throttle + 1)
    else
      raise e
    end
  end

  def self.noinclude_pp(pps)
    has_doc = @content =~ /\{\{\s*(?:Template\:)?(?:#{doc_templates.join('|')})\s*\}\}/
    has_collapsable_option = @content =~ /\{\{\s*(?:Template\:)?(?:#{collapsable_option_templates.join('|')})\}\}/

    if has_doc || has_collapsable_option
      @edit_summaries << 'Removing protection templates that are automatically generated by ' +
        (has_doc ? '{{documentation}}' : '{{collapsable option}}')
      return @content
    end

    @edit_summaries << 'Wrapping protection templates in <noinclude>'

    # FIXME: check to make sure it's not already in a noinclude and the bot just isn't able to figure out what to fix
    if @content.scan(/\A\<noinclude\>.*?\<\/noinclude\>/).any?
      @content.sub(/\A\<noinclude\>/, "<noinclude>#{pps}")
    else
      "<noinclude>#{pps}</noinclude>\n" + @content
    end
  end

  def self.repair_existing_pps
    new_pps = []
    needs_pp_added = false
    existing_types = []

    # find which templates they used and normalize them
    pp_hash.keys.each do |old_pp_type|
      matches = @content.scan(/\{\{\s*(#{old_pp_type})\s*(?:\|.*?(small\s*=\s*\w+)|\}\})/i).flatten
      next unless matches.any?

      opts = {
        pp_type: pp_type = pp_hash[matches[0]],
        type: pp_protect_type[pp_type.to_sym],
        small: matches[1].present?
      }

      if ['permanently protected', 'temporarily protected'].include?(opts[:pp_type])
        # edge case
        if @is_talk_page
          namespace, subject = @title.scan(/^(\w+ )?talk\:(.*)/i).flatten
          subject_edit_protection = protection_by_type(protect_info("#{namespace}:#{subject}").first, 'edit')

          # skip, forcing template to be removed if subject page is not template/sysop protected
          unless %w(templateeditor sysop).include?(subject_edit_protection['level'])
            @edit_summaries << "Removing {{#{old_pp_type}}} as subject page is not protected"
            next
          end
        else
          opts[:deactive] = true
          @edit_summaries << "Deactiving invalid use of [[Template:#{opts[:pp_type].capitalize}]]"
        end
      elsif !(protections(@page_obj) || flags(@page_obj))
        # no protection, then no template
        @edit_summaries << "Removing {{#{old_pp_type}}} from unprotected page"
        next
      elsif opts[:pp_type] == 'pp' && opts[:type].blank?
        # try to figure out usage of generic {{pp}}
        opts[:type] = @content.scan(/\{\{\s*pp\s*(?:\|.*?action\s*\=\s*(.*?)\|?)\}\}/i).flatten.first

        # if a type couldn't be parsed, mark it as needing all templates to be added
        #   since they obviously don't know how to do it right
        needs_pp_added = true and next unless opts[:type]

        # reason (the 1= parameter) will be blp, dispute, sock, etc.
        if reason = @content.scan(/\{\{pp\s*\|(?:(?:1\=)?(\w+(?=\||\}\}))|.*?\|1\=(\w+))/).flatten.compact.first
          opts[:pp_type] = "pp-#{reason}"
        end
      end

      expiry_key = opts[:type] == 'flagged' ? 'protection_expiry' : 'expiry'
      opts[:expiry] = protection_by_type(@page_obj, opts[:type])[expiry_key] if valid_pp = protection_by_type(@page_obj, opts[:type])

      # invalid if protection type and template type mismatch (protection is edit but template is for move)
      unless valid_pp
        @edit_summaries << "Removing invalid use of {{#{old_pp_type}}}"
        next
      end

      # API response is cached
      if @mb.parse_date(opts[:expiry]) < @mb.now
        @edit_summaries << "Removing {{#{old_pp_type}}} from unprotected page"
        next
      end

      @edit_summaries << 'Repairing protection templates' unless @edit_summaries.any?
      existing_types << opts[:type]

      new_pps << build_pp_template(opts)
    end

    new_pps.join(@is_template ? '' : "\n") + (needs_pp_added ? auto_pps(existing_types) : '')
  end

  def self.auto_pps(existing_types = [])
    new_pps = ''
    (%w(edit move flagged) - existing_types).each do |type|
      next unless settings = protection_by_type(@page_obj, type)

      # FIXME: apparently user talk pages need to use pp-usertalk
      #   perhaps only when fully-protected? and the user has to be blocked?
      if type == 'flagged'
        pp_type = "pp-pc#{settings['level'].to_i + 1}"
      elsif type == 'move'
        pp_type = 'pp-move'
      elsif @is_template
        pp_type = 'pp-template'
      else
        pp_type = 'pp'
      end

      expiry_key = type == 'flagged' ? 'protection_expiry' : 'expiry'
      new_pps += build_pp_template(
        type: type,
        pp_type: pp_type,
        expiry: settings[expiry_key],
        small: true # just assume small=yes
      )
    end

    new_pps
  end

  def self.build_pp_template(opts)
    new_pp = '{{'

    new_pp += 'tlx|' if opts[:deactive]

    if opts[:expiry] == 'infinity'
      if opts[:type] == 'edit'
        opts[:pp_type] = 'pp-semi-indef'
      elsif opts[:type] == 'move'
        opts[:pp_type] = 'pp-move-indef'
      end
      new_pp += opts[:pp_type]
    else
      opts[:expiry] = DateTime.parse(opts[:expiry]).strftime('%H:%M, %-d %B %Y')
      new_pp += "#{opts[:pp_type]}|expiry=#{opts[:expiry]}"
      new_pp += "|action=#{opts[:type]}" if opts[:pp_type] == 'pp'
    end

    "#{new_pp}#{'|small=yes' if opts[:small]}}}"
  end

  def self.doc_templates
    %w(documentation doc docs)
  end

  def self.collapsable_option_templates
    ['cop', 'collapsable', 'collapsable option', 'collapsable_option']
  end

  def self.remove_pps
    # FIXME: remove <noinclude> if the pp is the only thing in it
    @content.gsub!(/\{\{\s*(?:Template\:)?(?:#{pp_hash.keys.flatten.join('|')}).*?\}\}\n*/i, '')
  end

  def self.protections(page)
    page.elements['protection'].present? && page.elements['protection'][0].present? ? page.elements['protection'] : nil
  end

  def self.flags(page)
    page.elements['flagged'].present? ? page.elements['flagged'] : nil
  end

  def self.protection_by_type(page, type)
    if type == 'flagged'
      flags(page).attributes rescue nil
    else
      protections(page).select { |p| p.attributes['type'] == type }.first.attributes rescue nil
    end
  end

  def self.protected?(page)
    (protections(page) || flags(page)).present?
  end

  # protection types
  def self.pp_hash
    return @pp_hash if @pp_hash

    # cache on disk for one week
    @mb.disk_cache('pp_hash', 604_800) do
      @pp_hash = {}

      pp_types.each do |pp_type|
        redirects("Template:#{pp_type}").each { |r| @pp_hash[r.sub(/^Template:/, '').downcase] = pp_type }
      end

      @pp_hash
    end
  end

  def self.pp_protect_type
    {
      'pp': '',
      'pp-move': 'move',
      'pp-pc1': 'flagged',
      'pp-pc2': 'flagged',
      'pp-dispute': 'edit',
      'pp-move-dispute': 'move',
      'pp-office': 'edit',
      'pp-blp': 'edit',
      'pp-sock': 'edit',
      'pp-template': 'edit',
      'pp-usertalk': 'edit',
      'pp-vandalism': 'edit',
      'pp-move-vandalism': 'move',
      'permanently protected': 'edit',
      'temporarily protected': 'edit',
      'pp-semi-indef': 'edit',
      'pp-move-indef': 'move'
    }
  end

  def self.pp_types
    pp_protect_type.keys
  end

  # Redis
  def self.cache_touched(page, action)
    key = "mb-fixpp-#{page.attributes['page_id']}"

    if action == :set
      @mb.redis_client.set(key, page.attributes['touched'])
      @mb.redis_client.expire(key, 10_800) # 3 hours
    else
      DateTime.parse(@mb.redis_client.get(key)) rescue @mb.now
    end
  end

  # API-related
  def self.protect_info(page)
    @mb.gateway.custom_query(
      prop: 'info|flagged|revisions',
      inprop: 'protection',
      rvprop: 'user',
      rvlimit: 1,
      titles: page
    ).elements['pages']
  end

  def self.category_members
    return @category_members if @category_members
    @mb.gateway.purge(CATEGORY)
    @category_members = @mb.gateway.custom_query(
      list: 'categorymembers',
      cmtitle: CATEGORY,
      cmlimit: 5000,
      cmprop: 'title',
      cmtype: 'page'
    ).elements['categorymembers'].map { |cm| cm.attributes['title'] }
  end

  def self.redirects(title)
    ret = @mb.gateway.custom_query(
      prop: 'redirects',
      titles: title
    ).elements['pages'][0].elements['redirects']
    [title] + (ret ? ret.map { |r| r.attributes['title'] } : [])
  end
end

FixPP.run
