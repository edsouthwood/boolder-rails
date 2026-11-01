# Remembers a contributor's name and email in the session, so the report and
# contribution forms come pre-filled next time.
module RemembersContributor
  extend ActiveSupport::Concern

  private

  def remembered_contributor
    { contributor_name: session[:contribution_name], contributor_email: session[:contribution_email] }
  end

  def remember_contributor(contribution)
    session[:contribution_name] = contribution.contributor_name
    session[:contribution_email] = contribution.contributor_email
  end
end
