# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplicationController do
  describe '#redirect_to_login_if_required' do
    let(:admin) { Fabricate(:admin) }

    before do
      admin  # to skip welcome wizard at home page `/`
      SiteSetting.login_required = true
    end

    it "should never cache a login redirect" do
      get "/"
      expect(response.headers["Cache-Control"]).to eq("no-cache, no-store")
    end

    it "should redirect to login normally" do
      get "/"
      expect(response).to redirect_to("/login")
    end

    it "should redirect to SSO if enabled" do
      SiteSetting.discourse_connect_url = 'http://someurl.com'
      SiteSetting.enable_discourse_connect = true
      get "/"
      expect(response).to redirect_to("/session/sso")
    end

    it "should redirect to authenticator if only one, and local logins disabled" do
      # Local logins and google enabled, direct to login UI
      SiteSetting.enable_google_oauth2_logins = true
      get "/"
      expect(response).to redirect_to("/login")

      # Only google enabled, login immediately
      SiteSetting.enable_local_logins = false
      get "/"
      expect(response).to redirect_to("/auth/google_oauth2")

      # Google and GitHub enabled, direct to login UI
      SiteSetting.enable_github_logins = true
      get "/"
      expect(response).to redirect_to("/login")
    end

    it "should not redirect to SSO when auth_immediately is disabled" do
      SiteSetting.auth_immediately = false
      SiteSetting.discourse_connect_url = 'http://someurl.com'
      SiteSetting.enable_discourse_connect = true

      get "/"
      expect(response).to redirect_to("/login")
    end

    it "should not redirect to authenticator when auth_immediately is disabled" do
      SiteSetting.auth_immediately = false
      SiteSetting.enable_google_oauth2_logins = true
      SiteSetting.enable_local_logins = false

      get "/"
      expect(response).to redirect_to("/login")
    end

    context "with omniauth in test mode" do
      before do
        OmniAuth.config.test_mode = true
        OmniAuth.config.add_mock(:google_oauth2,
          info: OmniAuth::AuthHash::InfoHash.new(
            email: "address@example.com",
          ),
          extra: {
            raw_info: OmniAuth::AuthHash.new(
              email_verified: true,
              email: "address@example.com",
            )
          }
        )
        Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:google_oauth2]
      end

      after do
        Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:google_oauth2] = nil
        OmniAuth.config.test_mode = false
      end

      it "should not redirect to authenticator if registration in progress" do
        SiteSetting.enable_local_logins = false
        SiteSetting.enable_google_oauth2_logins = true

        get "/"
        expect(response).to redirect_to("/auth/google_oauth2")

        expect(cookies[:authentication_data]).to eq(nil)

        get "/auth/google_oauth2/callback.json"
        expect(response).to redirect_to("/")
        expect(cookies[:authentication_data]).not_to eq(nil)

        get "/"
        expect(response).to redirect_to("/login")
      end
    end

    it 'contains authentication data when cookies exist' do
      cookie_data = "someauthenticationdata"
      cookies['authentication_data'] = cookie_data
      get '/login'
      expect(response.status).to eq(200)
      expect(response.body).to include("data-authentication-data=\"#{cookie_data}\"")
      expect(response.headers["Set-Cookie"]).to include("authentication_data=;") # Delete cookie
    end

    it 'deletes authentication data cookie even if already authenticated' do
      sign_in(Fabricate(:user))
      cookies['authentication_data'] = "someauthenticationdata"
      get '/'
      expect(response.status).to eq(200)
      expect(response.body).not_to include("data-authentication-data=")
      expect(response.headers["Set-Cookie"]).to include("authentication_data=;") # Delete cookie
    end
  end

  describe '#redirect_to_second_factor_if_required' do
    let(:admin) { Fabricate(:admin) }
    fab!(:user) { Fabricate(:user) }

    before do
      admin # to skip welcome wizard at home page `/`
    end

    it "should redirect admins when enforce_second_factor is 'all'" do
      SiteSetting.enforce_second_factor = "all"
      sign_in(admin)

      get "/"
      expect(response).to redirect_to("/u/#{admin.username}/preferences/second-factor")
    end

    it "should redirect users when enforce_second_factor is 'all'" do
      SiteSetting.enforce_second_factor = "all"
      sign_in(user)

      get "/"
      expect(response).to redirect_to("/u/#{user.username}/preferences/second-factor")
    end

    it "should not redirect anonymous users when enforce_second_factor is 'all'" do
      SiteSetting.enforce_second_factor = "all"
      SiteSetting.allow_anonymous_posting = true
      sign_in(user)

      post "/u/toggle-anon.json"
      expect(response.status).to eq(200)

      get "/"
      expect(response.status).to eq(200)
    end

    it "should redirect admins when enforce_second_factor is 'staff'" do
      SiteSetting.enforce_second_factor = "staff"
      sign_in(admin)

      get "/"
      expect(response).to redirect_to("/u/#{admin.username}/preferences/second-factor")
    end

    it "should not redirect users when enforce_second_factor is 'staff'" do
      SiteSetting.enforce_second_factor = "staff"
      sign_in(user)

      get "/"
      expect(response.status).to eq(200)
    end

    it "should not redirect admins when turned off" do
      SiteSetting.enforce_second_factor = "no"
      sign_in(admin)

      get "/"
      expect(response.status).to eq(200)
    end

    it "should not redirect users when turned off" do
      SiteSetting.enforce_second_factor = "no"
      sign_in(user)

      get "/"
      expect(response.status).to eq(200)
    end

    it "correctly redirects for Unicode usernames" do
      SiteSetting.enforce_second_factor = "all"
      SiteSetting.unicode_usernames = true
      user = sign_in(Fabricate(:unicode_user))

      get "/"
      expect(response).to redirect_to("/u/#{user.encoded_username}/preferences/second-factor")
    end

    context "when enforcing second factor for staff" do
      before do
        SiteSetting.enforce_second_factor = "staff"
        sign_in(admin)
      end

      context "when the staff member has not enabled TOTP or security keys" do
        it "redirects the staff to the second factor preferences" do
          get "/"
          expect(response).to redirect_to("/u/#{admin.username}/preferences/second-factor")
        end
      end

      context "when the staff member has enabled TOTP" do
        before do
          Fabricate(:user_second_factor_totp, user: admin)
        end

        it "does not redirects the staff to set up 2FA" do
          get "/"
          expect(response.status).to eq(200)
        end
      end

      context "when the staff member has enabled security keys" do
        before do
          Fabricate(:user_security_key_with_random_credential, user: admin)
        end

        it "does not redirects the staff to set up 2FA" do
          get "/"
          expect(response.status).to eq(200)
        end
      end
    end
  end

  describe 'invalid request params' do
    before do
      @old_logger = Rails.logger
      @logs = StringIO.new
      Rails.logger = Logger.new(@logs)
    end

    after do
      Rails.logger = @old_logger
    end

    it 'should not raise a 500 (nor should it log a warning) for bad params' do
      bad_str = (+"d\xDE").force_encoding('utf-8')
      expect(bad_str.valid_encoding?).to eq(false)

      get "/latest.json", params: { test: bad_str }

      expect(response.status).to eq(400)

      log = @logs.string

      if (log.include? 'exception app middleware')
        # heisentest diagnostics
        puts
        puts "EXTRA DIAGNOSTICS FOR INTERMITENT TEST FAIL"
        puts log
        puts ">> action_dispatch.exception"
        ex = request.env['action_dispatch.exception']
        puts ">> exception class: #{ex.class} : #{ex}"
      end

      expect(log).not_to include('exception app middleware')

      expect(response.parsed_body).to eq(
        "status" => 400,
        "error" => "Bad Request"
      )

    end
  end

  describe 'missing required param' do
    it 'should return a 400' do
      get "/search/query.json", params: { trem: "misspelled term" }

      expect(response.status).to eq(400)
      expect(response.parsed_body["errors"].first).to include("param is missing or the value is empty: term")
    end
  end

  describe 'build_not_found_page' do
    describe 'topic not found' do

      it 'should not redirect to permalink if topic/category does not exist' do
        topic = create_post.topic
        Permalink.create!(url: topic.relative_url, topic_id: topic.id + 1)
        topic.trash!

        SiteSetting.detailed_404 = false
        get topic.relative_url
        expect(response.status).to eq(404)

        SiteSetting.detailed_404 = true
        get topic.relative_url
        expect(response.status).to eq(410)
      end

      it 'should return permalink for deleted topics' do
        topic = create_post.topic
        external_url = 'https://somewhere.over.rainbow'
        Permalink.create!(url: topic.relative_url, external_url: external_url)
        topic.trash!

        get topic.relative_url
        expect(response.status).to eq(301)
        expect(response).to redirect_to(external_url)

        get "/t/#{topic.id}.json"
        expect(response.status).to eq(301)
        expect(response).to redirect_to(external_url)

        get "/t/#{topic.id}.json", xhr: true
        expect(response.status).to eq(200)
        expect(response.body).to eq(external_url)
      end

      it 'supports subfolder with permalinks' do
        set_subfolder "/forum"

        trashed_topic = create_post.topic
        trashed_topic.trash!
        new_topic = create_post.topic
        permalink = Permalink.create!(url: trashed_topic.relative_url, topic_id: new_topic.id)

        # no subfolder because router doesn't know about subfolder in this test
        get "/t/#{trashed_topic.slug}/#{trashed_topic.id}"
        expect(response.status).to eq(301)
        expect(response).to redirect_to("/forum/t/#{new_topic.slug}/#{new_topic.id}")

        permalink.destroy
        category = Fabricate(:category)
        permalink = Permalink.create!(url: trashed_topic.relative_url, category_id: category.id)
        get "/t/#{trashed_topic.slug}/#{trashed_topic.id}"
        expect(response.status).to eq(301)
        expect(response).to redirect_to("/forum/c/#{category.slug}/#{category.id}")

        permalink.destroy
        permalink = Permalink.create!(url: trashed_topic.relative_url, post_id: new_topic.posts.last.id)
        get "/t/#{trashed_topic.slug}/#{trashed_topic.id}"
        expect(response.status).to eq(301)
        expect(response).to redirect_to("/forum/t/#{new_topic.slug}/#{new_topic.id}/#{new_topic.posts.last.post_number}")
      end

      it 'should return 404 and show Google search for an invalid topic route' do
        get "/t/nope-nope/99999999"

        expect(response.status).to eq(404)

        response_body = response.body

        expect(response_body).to include(I18n.t('page_not_found.search_button'))
        expect(response_body).to have_tag("input", with: { value: 'nope nope' })
      end

      it 'should not include Google search if login_required is enabled' do
        SiteSetting.login_required = true
        sign_in(Fabricate(:user))
        get "/t/nope-nope/99999999"
        expect(response.status).to eq(404)
        expect(response.body).to_not include('google.com/search')
      end

      describe 'no logspam' do

        before do
          @orig_logger = Rails.logger
          Rails.logger = @fake_logger = FakeLogger.new
        end

        after do
          Rails.logger = @orig_logger
        end

        it 'should handle 404 to a css file' do

          Discourse.cache.delete("page_not_found_topics:#{I18n.locale}")

          topic1 = Fabricate(:topic)
          get '/stylesheets/mobile_1_4cd559272273fe6d3c7db620c617d596a5fdf240.css', headers: { 'HTTP_ACCEPT' => 'text/css,*/*,q=0.1' }
          expect(response.status).to eq(404)
          expect(response.body).to include(topic1.title)

          topic2 = Fabricate(:topic)
          get '/stylesheets/mobile_1_4cd559272273fe6d3c7db620c617d596a5fdf240.css', headers: { 'HTTP_ACCEPT' => 'text/css,*/*,q=0.1' }
          expect(response.status).to eq(404)
          expect(response.body).to include(topic1.title)
          expect(response.body).to_not include(topic2.title)

          expect(Rails.logger.fatals.length).to eq(0)
          expect(Rails.logger.errors.length).to eq(0)
          expect(Rails.logger.warnings.length).to eq(0)

        end
      end

      it 'should cache results' do
        Discourse.cache.delete("page_not_found_topics:#{I18n.locale}")
        Discourse.cache.delete("page_not_found_topics:fr")

        topic1 = Fabricate(:topic)
        get '/t/nope-nope/99999999'
        expect(response.status).to eq(404)
        expect(response.body).to include(topic1.title)

        topic2 = Fabricate(:topic)
        get '/t/nope-nope/99999999'
        expect(response.status).to eq(404)
        expect(response.body).to include(topic1.title)
        expect(response.body).to_not include(topic2.title)

        # Different locale should have different cache
        SiteSetting.default_locale = :fr
        get '/t/nope-nope/99999999'
        expect(response.status).to eq(404)
        expect(response.body).to include(topic1.title)
        expect(response.body).to include(topic2.title)
      end
    end
  end

  describe "#handle_theme" do
    let!(:theme) { Fabricate(:theme, user_selectable: true) }
    let!(:theme2) { Fabricate(:theme, user_selectable: true) }
    let!(:non_selectable_theme) { Fabricate(:theme, user_selectable: false) }
    fab!(:user) { Fabricate(:user) }
    fab!(:admin) { Fabricate(:admin) }

    before do
      sign_in(user)
    end

    it "selects the theme the user has selected" do
      user.user_option.update_columns(theme_ids: [theme.id])

      get "/"
      expect(response.status).to eq(200)
      expect(controller.theme_ids).to eq([theme.id])

      theme.update_attribute(:user_selectable, false)

      get "/"
      expect(response.status).to eq(200)
      expect(controller.theme_ids).to eq([SiteSetting.default_theme_id])
    end

    it "can be overridden with a cookie" do
      user.user_option.update_columns(theme_ids: [theme.id])

      cookies['theme_ids'] = "#{theme2.id}|#{user.user_option.theme_key_seq}"

      get "/"
      expect(response.status).to eq(200)
      expect(controller.theme_ids).to eq([theme2.id])

      theme2.update!(user_selectable: false, component: true)
      theme.add_relative_theme!(:child, theme2)
      cookies['theme_ids'] = "#{theme.id},#{theme2.id}|#{user.user_option.theme_key_seq}"

      get "/"
      expect(response.status).to eq(200)
      expect(controller.theme_ids).to eq([theme.id, theme2.id])
    end

    it "falls back to the default theme when the user has no cookies or preferences" do
      user.user_option.update_columns(theme_ids: [])
      cookies["theme_ids"] = nil
      theme2.set_default!

      get "/"
      expect(response.status).to eq(200)
      expect(controller.theme_ids).to eq([theme2.id])
    end

    it "can be overridden with preview_theme_id param" do
      sign_in(admin)
      cookies['theme_ids'] = "#{theme.id},#{theme2.id}|#{admin.user_option.theme_key_seq}"

      get "/", params: { preview_theme_id: theme2.id }
      expect(response.status).to eq(200)
      expect(controller.theme_ids).to eq([theme2.id])

      get "/", params: { preview_theme_id: non_selectable_theme.id }
      expect(controller.theme_ids).to eq([non_selectable_theme.id])
    end

    it "does not allow non privileged user to preview themes" do
      sign_in(user)
      get "/", params: { preview_theme_id: non_selectable_theme.id }
      expect(controller.theme_ids).to eq([SiteSetting.default_theme_id])
    end

    it "cookie can fail back to user if out of sync" do
      user.user_option.update_columns(theme_ids: [theme.id])
      cookies['theme_ids'] = "#{theme2.id}|#{user.user_option.theme_key_seq - 1}"

      get "/"
      expect(response.status).to eq(200)
      expect(controller.theme_ids).to eq([theme.id])
    end
  end

  describe 'Custom hostname' do

    it 'does not allow arbitrary host injection' do
      get("/latest",
        headers: {
          "X-Forwarded-Host" => "test123.com"
        }
      )

      expect(response.body).not_to include("test123")
    end
  end

  describe 'allow_embedding_site_in_an_iframe' do

    it "should have the 'X-Frame-Options' header with value 'sameorigin'" do
      get("/latest")
      expect(response.headers['X-Frame-Options']).to eq("SAMEORIGIN")
    end

    it "should not include the 'X-Frame-Options' header" do
      SiteSetting.allow_embedding_site_in_an_iframe = true
      get("/latest")
      expect(response.headers).not_to include('X-Frame-Options')
    end
  end

  describe 'Delegated auth' do
    let :public_key do
      <<~TXT
      -----BEGIN PUBLIC KEY-----
      MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDh7BS7Ey8hfbNhlNAW/47pqT7w
      IhBz3UyBYzin8JurEQ2pY9jWWlY8CH147KyIZf1fpcsi7ZNxGHeDhVsbtUKZxnFV
      p16Op3CHLJnnJKKBMNdXMy0yDfCAHZtqxeBOTcCo1Vt/bHpIgiK5kmaekyXIaD0n
      w0z/BYpOgZ8QwnI5ZwIDAQAB
      -----END PUBLIC KEY-----
      TXT
    end

    let :args do
      {
        auth_redirect: 'http://no-good.com',
        user_api_public_key: "not-a-valid-public-key"
      }
    end

    it 'disallows invalid public_key param' do
      args[:auth_redirect] = "discourse://auth_redirect"
      get "/latest", params: args

      expect(response.body).to eq(I18n.t("user_api_key.invalid_public_key"))
    end

    it 'does not allow invalid auth_redirect' do
      args[:user_api_public_key] = public_key
      get "/latest", params: args

      expect(response.body).to eq(I18n.t("user_api_key.invalid_auth_redirect"))
    end

    it 'does not redirect if one_time_password scope is disallowed' do
      SiteSetting.allow_user_api_key_scopes = "read|write"
      args[:user_api_public_key] = public_key
      args[:auth_redirect] = "discourse://auth_redirect"

      get "/latest", params: args

      expect(response.status).to_not eq(302)
      expect(response).to_not redirect_to("#{args[:auth_redirect]}?otp=true")
    end

    it 'redirects correctly with valid params' do
      SiteSetting.login_required = true
      args[:user_api_public_key] = public_key
      args[:auth_redirect] = "discourse://auth_redirect"

      get "/categories", params: args

      expect(response.status).to eq(302)
      expect(response).to redirect_to("#{args[:auth_redirect]}?otp=true")
    end
  end

  describe 'Content Security Policy' do
    it 'is enabled by SiteSettings' do
      SiteSetting.content_security_policy = false
      SiteSetting.content_security_policy_report_only = false

      get '/'

      expect(response.headers).to_not include('Content-Security-Policy')
      expect(response.headers).to_not include('Content-Security-Policy-Report-Only')

      SiteSetting.content_security_policy = true
      SiteSetting.content_security_policy_report_only = true

      get '/'

      expect(response.headers).to include('Content-Security-Policy')
      expect(response.headers).to include('Content-Security-Policy-Report-Only')
    end

    it 'can be customized with SiteSetting' do
      SiteSetting.content_security_policy = true

      get '/'
      script_src = parse(response.headers['Content-Security-Policy'])['script-src']

      expect(script_src).to_not include('example.com')

      SiteSetting.content_security_policy_script_src = 'example.com'

      get '/'
      script_src = parse(response.headers['Content-Security-Policy'])['script-src']

      expect(script_src).to include('example.com')
    end

    it 'does not set CSP when responding to non-HTML' do
      SiteSetting.content_security_policy = true
      SiteSetting.content_security_policy_report_only = true

      get '/latest.json'

      expect(response.headers).to_not include('Content-Security-Policy')
      expect(response.headers).to_not include('Content-Security-Policy-Report-Only')
    end

    it 'when GTM is enabled it adds the same nonce to the policy and the GTM tag' do
      SiteSetting.content_security_policy = true
      SiteSetting.gtm_container_id = 'GTM-ABCDEF'

      get '/latest'
      nonce = ApplicationHelper.google_tag_manager_nonce
      expect(response.headers).to include('Content-Security-Policy')

      script_src = parse(response.headers['Content-Security-Policy'])['script-src']
      expect(script_src.to_s).to include(nonce)
      expect(response.body).to include(nonce)
    end

    def parse(csp_string)
      csp_string.split(';').map do |policy|
        directive, *sources = policy.split
        [directive, sources]
      end.to_h
    end
  end

  it 'can respond to a request with */* accept header' do
    get '/', headers: { HTTP_ACCEPT: '*/*' }
    expect(response.status).to eq(200)
    expect(response.body).to include('Discourse')
  end

  it 'has canonical tag' do
    get '/', headers: { HTTP_ACCEPT: '*/*' }
    expect(response.body).to have_tag("link", with: { rel: "canonical", href: "http://test.localhost/" })
    get '/?query_param=true', headers: { HTTP_ACCEPT: '*/*' }
    expect(response.body).to have_tag("link", with: { rel: "canonical", href: "http://test.localhost/" })
    get '/latest?page=2&additional_param=true', headers: { HTTP_ACCEPT: '*/*' }
    expect(response.body).to have_tag("link", with: { rel: "canonical", href: "http://test.localhost/latest?page=2" })
    get '/404', headers: { HTTP_ACCEPT: '*/*' }
    expect(response.body).to have_tag("link", with: { rel: "canonical", href: "http://test.localhost/404" })
    topic = create_post.topic
    get "/t/#{topic.slug}/#{topic.id}"
    expect(response.body).to have_tag("link", with: { rel: "canonical", href: "http://test.localhost/t/#{topic.slug}/#{topic.id}" })
  end

  context "default locale" do
    before do
      SiteSetting.default_locale = :fr
      sign_in(Fabricate(:user))
    end

    after do
      I18n.reload!
    end

    context "with rate limits" do
      before do
        RateLimiter.clear_all!
        RateLimiter.enable
      end

      it "serves a LimitExceeded error in the preferred locale" do
        SiteSetting.max_likes_per_day = 1
        post1 = Fabricate(:post)
        post2 = Fabricate(:post)
        override = TranslationOverride.create(
          locale: "fr",
          translation_key: "rate_limiter.by_type.create_like",
          value: "French LimitExceeded error message"
        )
        I18n.reload!

        post "/post_actions.json", params: {
          id: post1.id, post_action_type_id: PostActionType.types[:like]
        }
        expect(response.status).to eq(200)

        post "/post_actions.json", params: {
          id: post2.id, post_action_type_id: PostActionType.types[:like]
        }
        expect(response.status).to eq(429)
        expect(response.parsed_body["errors"].first).to eq(override.value)
      end
    end

    it "serves an InvalidParameters error with the default locale" do
      override = TranslationOverride.create(
        locale: "fr",
        translation_key: "invalid_params",
        value: "French InvalidParameters error message"
      )
      I18n.reload!

      get "/search.json", params: { q: "hello\0hello" }
      expect(response.status).to eq(400)
      expect(response.parsed_body["errors"].first).to eq(override.value)
    end
  end

  describe "set_locale" do
    # Using /bootstrap.json because it returns a locale-dependent value
    def headers(locale)
      { HTTP_ACCEPT_LANGUAGE: locale }
    end

    context "allow_user_locale disabled" do
      context "accept-language header differs from default locale" do
        before do
          SiteSetting.allow_user_locale = false
          SiteSetting.default_locale = "en"
        end

        context "with an anonymous user" do
          it "uses the default locale" do
            get "/bootstrap.json", headers: headers("fr")
            expect(response.status).to eq(200)
            expect(response.parsed_body['bootstrap']['locale_script']).to end_with("en.js")
          end
        end

        context "with a logged in user" do
          it "it uses the default locale" do
            user = Fabricate(:user, locale: :fr)
            sign_in(user)

            get "/bootstrap.json", headers: headers("fr")
            expect(response.status).to eq(200)
            expect(response.parsed_body['bootstrap']['locale_script']).to end_with("en.js")
          end
        end
      end
    end

    context "set_locale_from_accept_language_header enabled" do
      context "accept-language header differs from default locale" do
        before do
          SiteSetting.allow_user_locale = true
          SiteSetting.set_locale_from_accept_language_header = true
          SiteSetting.default_locale = "en"
        end

        context "with an anonymous user" do
          it "uses the locale from the headers" do
            get "/bootstrap.json", headers: headers("fr")
            expect(response.status).to eq(200)
            expect(response.parsed_body['bootstrap']['locale_script']).to end_with("fr.js")
          end

          it "doesn't leak after requests" do
            get "/bootstrap.json", headers: headers("fr")
            expect(response.status).to eq(200)
            expect(response.parsed_body['bootstrap']['locale_script']).to end_with("fr.js")
            expect(I18n.locale.to_s).to eq(SiteSettings::DefaultsProvider::DEFAULT_LOCALE)
          end
        end

        context "with a logged in user" do
          let(:user) { Fabricate(:user, locale: :fr) }

          before do
            sign_in(user)
          end

          it "uses the user's preferred locale" do
            get "/bootstrap.json", headers: headers("fr")
            expect(response.status).to eq(200)
            expect(response.parsed_body['bootstrap']['locale_script']).to end_with("fr.js")
          end

          it "serves a 404 page in the preferred locale" do
            get "/missingroute", headers: headers("fr")
            expect(response.status).to eq(404)
            expected_title = I18n.t("page_not_found.title", locale: :fr)
            expect(response.body).to include(CGI.escapeHTML(expected_title))
          end

          it "serves a RenderEmpty page in the preferred locale" do
            get "/u/#{user.username}/preferences/interface"
            expect(response.status).to eq(200)
            expect(response.body).to have_tag('script', with: { src: "/assets/locales/fr.js" })
          end
        end
      end

      context "the preferred locale includes a region" do
        it "returns the locale and region separated by an underscore" do
          SiteSetting.allow_user_locale = true
          SiteSetting.set_locale_from_accept_language_header = true
          SiteSetting.default_locale = "en"

          get "/bootstrap.json", headers: headers("zh-CN")
          expect(response.status).to eq(200)
          expect(response.parsed_body['bootstrap']['locale_script']).to end_with("zh_CN.js")
        end
      end

      context 'accept-language header is not set' do
        it 'uses the site default locale' do
          SiteSetting.allow_user_locale = true
          SiteSetting.default_locale = 'en'

          get "/bootstrap.json", headers: headers("")
          expect(response.status).to eq(200)
          expect(response.parsed_body['bootstrap']['locale_script']).to end_with("en.js")
        end
      end
    end
  end
end
