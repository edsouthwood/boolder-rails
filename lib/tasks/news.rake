namespace :news do
  # What's new on the public site, for a social media post (the bowda-news Claude skill runs
  # this). Read-only. Writes digest.json and, when a new photo has lines on it, post.jpg.
  #
  #   bin/rails "news:digest[7,tmp/news]"
  #   ADMINS=~/.config/bowda-news/admins.yml PHOTO_CREDIT="Sam" bin/rails news:digest
  #
  # ADMINS: YAML of admin login name => name to credit (else the login name is used).
  # PHOTO_CREDIT: overrides the credit printed on the image.
  # TOPO: id of a public photo to feature instead of the one with most new lines.
  desc "Write digest.json and post.jpg about the last DAYS days (default 7) into OUT_DIR"
  task :digest, [ :days, :out_dir ] => :environment do |_task, args|
    days = (args[:days].presence || 7).to_i
    out = Pathname(args[:out_dir].presence || Rails.root.join("tmp/news/#{Date.current}")).expand_path
    FileUtils.mkdir_p(out)

    digest = NewsDigest.new(since: days.days.ago.beginning_of_day)
    data = digest.call
    File.write(out.join("digest.json"), JSON.pretty_generate(data))
    puts "Wrote #{out.join('digest.json')}"

    topo = ENV["TOPO"].present? ? Topo.find(ENV["TOPO"]) : digest.featured_topo
    abort "Topo #{topo.id} isn't public" if topo && !topo.publicly_visible?

    if topo
      admins = ENV["ADMINS"].present? && File.exist?(File.expand_path(ENV["ADMINS"])) ? YAML.safe_load_file(File.expand_path(ENV["ADMINS"])) || {} : {}
      credit = ENV["TOPO"].present? ? digest.credit_for_topo(topo) : data.dig(:featured_topo, :credit)
      name = ENV["PHOTO_CREDIT"].presence ||
        (credit && (credit[:kind] == "admin" ? admins.fetch(credit[:name], credit[:name]) : credit[:name])) ||
        "the bowda team"
      counts = data[:counts]
      headline = [
        ("#{counts[:problems]} new #{'problem'.pluralize(counts[:problems])}" if counts[:problems].positive?),
        ("#{counts[:areas]} new #{'crag'.pluralize(counts[:areas])}" if counts[:areas].positive?)
      ].compact.join(" · ").presence || "New on bowda.rocks"

      path = NewsDigest::Image.new(topo: topo, headline: headline, credit: name).write(out.join("post.jpg"))
      puts "Wrote #{path}"
    else
      puts "No new photo with lines on it, so no image"
    end
  end
end
