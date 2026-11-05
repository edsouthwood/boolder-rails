xml.instruct! :xml, version: "1.0", encoding: "UTF-8"
xml.urlset xmlns: "http://www.sitemaps.org/schemas/sitemap/0.9" do
  url = ->(loc, lastmod, changefreq, priority) do
    xml.url do
      xml.loc loc
      xml.lastmod lastmod.to_date.iso8601 if lastmod
      xml.changefreq changefreq
      xml.priority priority
    end
  end

  newest_area = areas.maximum(:updated_at)
  url.(root_url, newest_area, "weekly", 1.0)
  url.(map_url, newest_area, "weekly", 0.8)
  url.(areas_url, newest_area, "weekly", 0.8)

  areas.each do |area|
    url.(area_url(area), area.updated_at, "weekly", 0.9)
    url.(area_problems_url(area), area.updated_at, "weekly", 0.7)
  end

  problems.each do |problem|
    url.(area_problem_url(problem.area, problem), problem.updated_at, "monthly", 0.6)
  end

  circuits.each do |circuit|
    url.(circuit_url(circuit), circuit.updated_at, "monthly", 0.5)
  end
end
