namespace :admin do
  desc "Copy the admin_accounts credentials list into Admin → Accounts (skips usernames already there)"
  task import_accounts: :environment do
    raw = Rails.application.credentials.admin_accounts
    abort "No admin_accounts in the credentials file" if raw.blank?

    raw.to_h.each do |username, value|
      username = username.to_s
      if AdminAccount.exists?(username: username.strip.downcase)
        puts "  skip #{username}: already an account"
        next
      end

      config = value.is_a?(String) ? { password: value, role: "super_admin" } : value.to_h.with_indifferent_access
      account = AdminAccount.new(username: username, role: config[:role].presence || "super_admin",
        area_slugs: Array(config[:areas]), password: config[:password].to_s)
      account.audit_comment = "imported from credentials"
      # Existing passwords may be shorter than new ones must be; keep them working
      if account.valid? || account.errors.attribute_names == [ :password ]
        account.save!(validate: false)
        short = account.password.length < AdminAccount::MIN_PASSWORD_LENGTH
        puts "  added #{account.username} (#{account.role}#{": #{account.area_slugs.join(", ")}" if account.area_slugs.any?})#{" — password is short: ask them to change it" if short}"
      else
        puts "  NOT added #{username}: #{account.errors.full_messages.to_sentence}"
      end
    end
    puts AdminAccount.any_super_admin? ? "Logins now use Admin → Accounts." : "No enabled super admin yet, so logins still use the credentials file."
  end

  desc "Emergency way back in: set (or create) a super admin's password. ADMIN=name, then type the password"
  task set_password: :environment do
    require "io/console"
    username = ENV["ADMIN"].presence || abort("Usage: bin/rails admin:set_password ADMIN=username")
    print "New password for #{username} (at least #{AdminAccount::MIN_PASSWORD_LENGTH} characters): "
    password = $stdin.tty? ? $stdin.noecho(&:gets).to_s.chomp : $stdin.gets.to_s.chomp
    puts

    account = AdminAccount.find_or_initialize_by(username: username.strip.downcase)
    account.assign_attributes(password: password, role: "super_admin", disabled_at: nil)
    account.audit_comment = "password set from the server"
    if account.save
      puts "#{account.username} is an enabled super admin with the new password, signed out everywhere else."
    else
      abort account.errors.full_messages.to_sentence
    end
  end
end
