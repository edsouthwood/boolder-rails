# Edit distance between two strings (insertions, deletions and substitutions all cost 1).
# Used to flag near-duplicate problem names on imports.
module Levenshtein
  def self.distance(a, b)
    return b.length if a.empty?
    return a.length if b.empty?

    previous = (0..b.length).to_a
    a.each_char.with_index(1) do |char_a, i|
      current = [ i ]
      b.each_char.with_index(1) do |char_b, j|
        cost = char_a == char_b ? 0 : 1
        current << [ previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost ].min
      end
      previous = current
    end
    previous.last
  end
end
