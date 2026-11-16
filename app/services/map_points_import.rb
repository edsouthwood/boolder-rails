# Reads a KML file of map points (folders of named pins, as exported from a web map tool),
# works out what importing it would change, and applies it.
#
# Each folder goes to an area (an existing one with the same name, or a new unpublished one),
# to parking, or is skipped. In an area, each point is matched by name to a listed boulder and
# gives it an approximate location (boulders.location), the guide for drawing its outline in
# the boulder editor. A point with no match becomes a new boulder name, without an outline.
#
# Points never create outlines: an outline is only ever drawn (or taken from LiDAR) by hand.
class MapPointsImport
  MAX_BYTES = 2.megabytes

  # A point within this of an unnamed outline offers to name that outline (ticked within ADOPT_METRES)
  OUTLINE_METRES = 15
  ADOPT_METRES = 5
  # A point this far from the outline of the boulder it names gets a warning
  FAR_METRES = 15
  # An existing parking spot this close to a parking point is the same one
  PARKING_METRES = 20
  # A location this close to the saved one isn't a change
  SAME_METRES = 1

  # Short forms used in map pin names, expanded word by word ("Waller Twr" → "Waller Tower")
  ABBREVIATIONS = {
    "b" => "Boulder", "bs" => "Boulders", "bldr" => "Boulder", "blk" => "Block",
    "wl" => "Wall", "twr" => "Tower", "rf" => "Roof", "btrs" => "Buttress", "btr" => "Buttress",
    "clstr" => "Cluster", "ftre" => "Feature", "rm" => "Room", "dble" => "Double", "pncke" => "Pancake",
    "sth" => "South", "nth" => "North"
  }.freeze
  # Left off the ends of names when comparing ("The Yak" = "Yak B", "Bez's" = "Bez's Block")
  GENERIC_ENDINGS = %w[boulder boulders block].freeze

  Point = Data.define(:key, :name, :description, :lat, :lon) do
    def uncertain? = name.strip.end_with?("?")
    def wkt = "POINT(#{lon} #{lat})"
  end
  Folder = Data.define(:key, :name, :points)
  Skipped = Data.define(:folder, :text, :reason)
  Parsed = Data.define(:folders, :skipped)

  class ParseError < StandardError; end

  # target: "area:<id>", "new", "parking" or "skip"
  FolderPlan = Struct.new(:folder, :target, :area, :new_area_name, :points, keyword_init: true) do
    def kind = target.split(":").first
  end

  # What applying would do with one point in an area:
  #   :match          names one listed boulder (two for "A / B"): it gets the location
  #   :possible_match similar names only: nothing happens unless one is chosen
  #   :new            no such boulder yet: created (without an outline) if chosen
  #   :on_map         names a boulder that's already drawn: nothing to do (warns when far)
  # In parking folders: :new (a parking spot to create) or :exists (one is already there).
  PointPlan = Struct.new(:point, :action, :boulders, :similar, :outline, :outline_metres, :new_name,
                         :saved_metres, :far_metres, :existing_poi, keyword_init: true) do
    def default_choice
      case action
      when :match then point.uncertain? ? "skip" : "boulder:#{boulders.map(&:id).join(",")}"
      when :new then point.uncertain? ? "skip" : "new"
      else "skip"
      end
    end

    # Ticked when an unnamed outline is close enough to be the same rock
    def adopt_by_default? = outline.present? && outline_metres <= ADOPT_METRES

    # The chosen boulder(s) already have a location somewhere else
    def moves_location? = saved_metres.present? && saved_metres > SAME_METRES

    def no_change?
      action == :exists || (action == :match && saved_metres && saved_metres <= SAME_METRES && outline.nil?)
    end
  end

  def self.parse(text)
    text = text.to_s.dup.force_encoding(Encoding::UTF_8).delete_prefix("﻿")
    raise ParseError, "That's a KMZ (zipped) file. Export the map as KML, or unzip it and choose the .kml inside." if text.start_with?("PK")

    doc = begin
      Nokogiri::XML(text, nil, "UTF-8", Nokogiri::XML::ParseOptions::STRICT | Nokogiri::XML::ParseOptions::NONET)
    rescue Nokogiri::XML::SyntaxError => e
      raise ParseError, "The file isn't valid KML (#{e.message.squish.truncate(120)})."
    end
    doc.remove_namespaces!
    raise ParseError, "The file isn't KML: it has no <kml> element." unless doc.root&.name == "kml"

    folders = {}
    skipped = []
    doc.xpath("//Placemark").each_with_index do |placemark, index|
      folder_name = placemark.ancestors("Folder").first&.at_xpath("name")&.text&.squish.presence ||
        doc.at_xpath("//Document/name")&.text&.squish.presence || "Points"
      name = placemark.at_xpath("name")&.text&.squish
      coordinates = placemark.at_xpath("Point/coordinates")&.text.to_s.split(/\s+/).reject(&:empty?)
      lon, lat = coordinates.first.to_s.split(",").map { |value| Float(value, exception: false) }

      if name.blank?
        skipped << Skipped.new(folder: folder_name, text: "(no name)", reason: "pin without a name")
      elsif coordinates.empty?
        skipped << Skipped.new(folder: folder_name, text: name, reason: "not a single point (a line or a shape)")
      elsif coordinates.size > 1 || lat.nil? || lon.nil? || lat.abs > 90 || lon.abs > 180
        skipped << Skipped.new(folder: folder_name, text: name, reason: "coordinates aren't a single point")
      else
        folder = folders[folder_name] ||= Folder.new(key: "f#{folders.size}", name: folder_name, points: [])
        folder.points << Point.new(key: "p#{index}", name: name,
          description: placemark.at_xpath("description")&.text&.squish.presence, lat: lat, lon: lon)
      end
    end
    Parsed.new(folders: folders.values, skipped: skipped)
  end

  # "Waller Twr" → "Waller Tower", "Mini B?" → "Mini Boulder", "Slabs & Aretes" → "Slabs and Aretes"
  def self.expand(name)
    name.to_s.delete_suffix("?").gsub("&", " and ").split(/(\s+)/).map do |word|
      ABBREVIATIONS[word.downcase] || word
    end.join.squish
  end

  # For comparing: expanded, normalized, without a leading "The" or a generic ending
  def self.core(name)
    words = CragListImport.normalize(expand(name)).split
    words.shift if words.first == "the" && words.size > 1
    words.pop if GENERIC_ENDINGS.include?(words.last) && words.size > 1
    words.join(" ")
  end

  # Close enough to suggest: one name's words all in the other's, a near-miss spelling, or one a prefix of the other
  def self.similar?(a, b)
    return false if a.empty? || b.empty? || a == b

    a_words, b_words = a.split, b.split
    (a_words - b_words).empty? || (b_words - a_words).empty? ||
      ([ a, b ].min_by(&:length).length >= 5 && Levenshtein.distance(a, b) <= 2) ||
      ([ a, b ].min_by(&:length).length >= 3 && (a.start_with?(b) || b.start_with?(a)))
  end

  # The names a pin's name could mean: "A / B" is two boulders, "A - B" may be the boulder and a
  # note (tried as a whole first)
  def self.name_options(name)
    parts = name.split(%r{\s+/\s+})
    return parts.map { |part| [ part ] } if parts.size > 1

    whole, before_dash = name, name.split(/\s+-\s+/).first
    before_dash == whole ? [ [ whole ] ] : [ [ whole, before_dash ] ]
  end

  attr_reader :parsed

  # targets: { folder key => "area:<id>" | "new" | "parking" | "skip" }; area_names: { folder key => name }
  def initialize(text, targets: {}, area_names: {})
    @parsed = self.class.parse(text)
    @targets = targets.to_h.transform_keys(&:to_s)
    @area_names = area_names.to_h.transform_keys(&:to_s)
  end

  def preview
    @preview ||= parsed.folders.map { |folder| plan_folder(folder) }
  end

  # choices: { point key => "skip" | "new" | "boulder:<id>[,<id>]" } (unset: the default)
  # adopt: point keys whose nearby unnamed outline should take the boulder's name
  # names: { point key => name for a new boulder }
  # replace: point keys whose boulder's saved location should move to the point
  # parking: point keys of parking points to create (nil: all of the new ones)
  def apply!(choices: {}, adopt: nil, names: {}, replace: [], parking: nil)
    choices = choices.to_h.transform_keys(&:to_s)
    names = names.to_h.transform_keys(&:to_s)
    adopt = adopt&.map(&:to_s)&.to_set
    replace = replace.map(&:to_s).to_set
    parking = parking&.map(&:to_s)&.to_set
    summary = Hash.new(0)

    Boulder.transaction do
      preview.each do |folder_plan|
        case folder_plan.kind
        when "skip"
          summary[:skipped] += folder_plan.points.size
        when "parking"
          folder_plan.points.each do |plan|
            if plan.action == :exists || (parking && !parking.include?(plan.point.key))
              summary[:skipped] += 1
            else
              create_parking!(plan.point)
              summary[:parking_created] += 1
            end
          end
        else
          area = folder_plan.area || create_area!(folder_plan, summary)
          taken = area.boulders.where.not(name: nil).pluck(:name).map(&:downcase).to_set
          folder_plan.points.each do |plan|
            wants_adopt = adopt ? adopt.include?(plan.point.key) : plan.adopt_by_default?
            apply_point!(area, plan, choices[plan.point.key] || plan.default_choice,
              names[plan.point.key], wants_adopt, replace.include?(plan.point.key), taken, summary)
          end
        end
      end
    end
    summary
  end

  private

  def plan_folder(folder)
    target = @targets[folder.key].presence || default_target(folder)
    area = (id = target[/\Aarea:(\d+)\z/, 1]) && Area.find_by(id: id)
    target = "new" if target.start_with?("area:") && area.nil?
    target = "skip" unless target.start_with?("area:") || %w[new parking skip].include?(target)

    points = case target
    when "parking" then folder.points.map { |point| plan_parking(point) }
    when "skip" then []
    else plan_area_points(folder.points, area)
    end
    FolderPlan.new(folder: folder, target: target, area: area,
      new_area_name: @area_names[folder.key].to_s.squish.presence || folder.name, points: points)
  end

  def default_target(folder)
    return "parking" if CragListImport.normalize(folder.name).match?(/\A(car )?park(ing)?s?\z|\Acar ?parks?\z/)

    key = CragListImport.normalize(folder.name)
    area = Area.all.find do |candidate|
      [ candidate.name, candidate.short_name, candidate.slug ].compact.any? { |name| CragListImport.normalize(name) == key }
    end
    area ? "area:#{area.id}" : "new"
  end

  def plan_parking(point)
    existing = Poi.parking.where("ST_DWithin(location, ST_GeomFromText(?, 4326)::geography, ?)", point.wkt, PARKING_METRES).first
    PointPlan.new(point: point, action: existing ? :exists : :new, boulders: [], similar: [], existing_poi: existing)
  end

  def plan_area_points(points, area)
    plans = match_points(points, area)
    # An unnamed outline near several points is only offered to the nearest one
    plans.select(&:outline).group_by { |plan| plan.outline.id }.each_value do |near|
      near.sort_by(&:outline_metres).drop(1).each { |plan| plan.outline = plan.outline_metres = nil }
    end
    plans
  end

  def match_points(points, area)
    listed = area ? area.boulders.where.not(name: nil).to_a : []
    by_core = listed.group_by { |boulder| self.class.core(boulder.name) }
    claimed = Set.new

    points.map do |point|
      matches = self.class.name_options(point.name).map do |options|
        options.lazy.map { |option| by_core[self.class.core(option)] }.find(&:present?) || []
      end
      found = matches.map { |candidates| candidates.reject { |boulder| claimed.include?(boulder.id) } }

      plan = if matches.all?(&:one?) && found.all?(&:one?)
        boulders = found.map(&:first)
        claimed.merge(boulders.map(&:id))
        if boulders.all?(&:placed?)
          PointPlan.new(point: point, action: :on_map, boulders: boulders, similar: [],
            far_metres: boulders.map { |boulder| metres_from_outline(boulder, point) }.max.then { _1 if _1 > FAR_METRES })
        else
          saved = boulders.filter_map { |boulder| metres_between(boulder.location, point) if boulder.location }.max
          PointPlan.new(point: point, action: :match, boulders: boulders, similar: [], saved_metres: saved)
        end
      else
        cores = self.class.name_options(point.name).flatten.map { |option| self.class.core(option) }
        similar = (matches.flatten + listed.select do |boulder|
          cores.any? { |core| self.class.similar?(core, self.class.core(boulder.name)) }
        end).uniq.sort_by { |boulder| [ claimed.include?(boulder.id) ? 1 : 0, boulder.name ] }
        PointPlan.new(point: point, action: similar.any? ? :possible_match : :new, boulders: [], similar: similar)
      end

      plan.new_name = self.class.expand(point.name)
      if area && plan.action != :on_map
        plan.outline, plan.outline_metres = nearest_unnamed_outline(area, point)
      end
      plan
    end
  end

  def apply_point!(area, plan, choice, new_name, wants_adopt, wants_replace, taken, summary)
    return if plan.action == :on_map

    boulders = case choice
    when "new"
      name = unique_name(new_name.to_s.squish.presence || plan.new_name, taken)
      [ area.boulders.create!(name: name).tap { summary[:boulders_created] += 1 } ]
    when /\Aboulder:([\d,]+)\z/
      ids = $1.split(",").map(&:to_i)
      allowed = (plan.boulders + plan.similar).index_by(&:id)
      ids.filter_map { |id| allowed[id] }.uniq
    else
      []
    end
    if boulders.empty?
      summary[:skipped] += 1
      return
    end

    point = FACTORY.point(plan.point.lon, plan.point.lat)
    boulders.each do |boulder|
      boulder.reload
      next if boulder.placed?

      if boulder.location.nil? || wants_replace || metres_between(boulder.location, plan.point) <= SAME_METRES
        summary[:located] += 1 if boulder.location.nil? || metres_between(boulder.location, plan.point) > SAME_METRES
        boulder.update!(location: point)
      else
        summary[:location_kept] += 1
      end
    end

    if wants_adopt && plan.outline && boulders.one? && Boulder.exists?(plan.outline.id)
      outline = Boulder.find(plan.outline.id)
      if outline.name.nil?
        outline.absorb!(boulders.first)
        outline.update!(location: point) if outline.location.nil?
        summary[:outlines_named] += 1
      end
    end
  end

  def create_area!(folder_plan, summary)
    summary[:areas_created] += 1
    name = folder_plan.new_area_name
    Area.create!(name: name, slug: Area.unique_slug_for(name), published: false)
  end

  def create_parking!(point)
    name = [ point.name, ("(#{point.description.downcase})" if point.description) ].compact.join(" ").truncate(80)
    Poi.create!(poi_type: "parking", name: name, short_name: point.name.truncate(40),
      location: FACTORY.point(point.lon, point.lat),
      google_url: "https://www.google.com/maps/search/?api=1&query=#{point.lat},#{point.lon}")
  end

  # "Mini Boulder" taken → "Mini Boulder 2"
  def unique_name(name, taken)
    candidate = name
    (2..).each do |n|
      break unless taken.include?(candidate.downcase)
      candidate = "#{name} #{n}"
    end
    taken << candidate.downcase
    candidate
  end

  def nearest_unnamed_outline(area, point)
    outline = area.boulders.placed.where(name: nil).
      where("ST_DWithin(polygon, ST_GeomFromText(?, 4326)::geography, ?)", point.wkt, OUTLINE_METRES).
      order(Arel.sql(Boulder.sanitize_sql_array([ "ST_Distance(polygon, ST_GeomFromText(?, 4326)::geography)", point.wkt ]))).first
    outline ? [ outline, metres_from_outline(outline, point) ] : [ nil, nil ]
  end

  def metres_from_outline(boulder, point)
    Boulder.where(id: boulder.id).pick(Arel.sql(Boulder.sanitize_sql_array(
      [ "ST_Distance(polygon, ST_GeomFromText(?, 4326)::geography)", point.wkt ]))).to_f.round(1)
  end

  def metres_between(location, point)
    Boulder.connection.select_value(Boulder.sanitize_sql_array(
      [ "SELECT ST_Distance(ST_GeomFromText(?, 4326)::geography, ST_GeomFromText(?, 4326)::geography)", location.as_text, point.wkt ])).to_f.round(1)
  end
end
