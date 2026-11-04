SitemapGenerator::Sitemap.default_host = "https://dartmoorbouldering.com"
SitemapGenerator::Sitemap.compress = false

SitemapGenerator::Sitemap.create do
  add root_path, changefreq: "weekly", priority: 1.0
  add map_path, changefreq: "weekly", priority: 0.8

  Area.published.find_each do |area|
    add area_path(area), changefreq: "weekly", priority: 0.9
    add area_problems_path(area), changefreq: "weekly", priority: 0.7
  end

  Problem.with_location.joins(:area).where(areas: { published: true }).find_each do |problem|
    add area_problem_path(problem.area, problem), changefreq: "monthly", priority: 0.6
  end

  Circuit.joins(:problems).distinct.find_each do |circuit|
    add circuit_path(circuit), changefreq: "monthly", priority: 0.5
  end
end
