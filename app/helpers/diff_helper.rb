module DiffHelper
  # Word-level HTML diff, same argument order as Differ.diff_by_word(to, from).
  # Differ's HTML formatter interpolates the text raw, so both sides are escaped first:
  # the values come from problem names, descriptions etc. that area admins (and, via
  # contributions, the public) can set.
  def word_diff_html(to, from)
    Differ.diff_by_word(ERB::Util.html_escape(to.to_s), ERB::Util.html_escape(from.to_s)).format_as(:html).html_safe
  end
end
