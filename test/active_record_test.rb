# require a specific AR version.
version = ENV["AR_VERSION"]
gem "activerecord", "~> #{version}" if version
require "active_record"
require "active_record/version"
version = ActiveRecord::VERSION::STRING
warn "Using activerecord #{version}"

# replicate must be loaded after AR
require "test_helper"

# create the sqlite db on disk
dbfile = File.expand_path("../db", __FILE__)
File.unlink dbfile if File.exist?(dbfile)
ActiveRecord::Base.establish_connection(:adapter => "sqlite3", :database => dbfile)

# load schema
ActiveRecord::Migration.verbose = false
ActiveRecord::Schema.define do
  create_table "users", :force => true do |t|
    t.string   "login"
    t.datetime "created_at"
    t.datetime "updated_at"
  end

  create_table "profiles", :force => true do |t|
    t.integer  "user_id"
    t.string   "name"
    t.string   "homepage"
  end

  create_table "emails", :force => true do |t|
    t.integer  "user_id"
    t.string   "email"
    t.datetime "created_at"
  end

  create_table "domains", :force => true do |t|
    t.string "host"
  end

  create_table "web_pages", :force => true do |t|
    t.string "url"
    t.string "domain_host"
  end

  create_table "notes", :force => true do |t|
    t.integer "notable_id"
    t.string  "notable_type"
  end

  create_table "namespaced", :force => true

  create_table "domains_users", :force => true do |t|
    t.integer "user_id"
    t.integer "domain_id"
  end
end


# Base test class for setting up fixture data and ensuring each test has a clean
# base state to work with
class ActiveRecordTest < Minitest::Test

  DumpedObject = Struct.new(:type, :id, :attrs, :obj)

  def setup
    @dumper = Replicate::Dumper.new
    @loader = Replicate::Loader.new
  end

  def around(&block)
    ActiveRecord::Base.transaction do
      block.call

      # Roll everything back at the end of the test for a clean data reset
      raise ActiveRecord::Rollback
    end
  end

  def dump(*objects)
    results = []
    @dumper.listen { |type, id, attrs, obj| results << DumpedObject.new(type, id, attrs, obj) }

    @dumper.dump(*objects)
    results
  end

  def load(objects)
    objects.each { |dumped| @loader.feed dumped.type, dumped.id, dumped.attrs }
  end

end

class EnableDumpingTest < ActiveRecordTest

  class User < ActiveRecord::Base
  end

  class Email < ActiveRecord::Base
    replicate_enable
  end

  def test_class_cannot_be_dumped_by_default
    user = User.create! :login => "rtomayko"
    objects = dump(user)

    assert_equal 0, objects.size, "Dumped the user when it shouldn't have: #{objects}"
  end

  def test_class_dumps_when_replicate_enabled
    email = Email.create! :email => "test@user.com"
    objects = dump(email)

    assert_equal 1, objects.size

    dumped = objects[0]
    assert_equal "EnableDumpingTest::Email", dumped.type
    assert_equal email.id, dumped.id
    assert_equal email, dumped.obj
  end

  def test_dumps_multiple_enabled_classes
    e1 = Email.create! :email => "test1@user.com"
    e2 = Email.create! :email => "test2@user.com"
    e3 = Email.create! :email => "test3@user.com"

    objects = dump(e1, e2, e3)

    assert_equal 3, objects.size
  end

  def test_does_not_dump_disabled_classes_in_list_mixed_with_enabled_classes
    email = Email.create! :email => "test@user.com"
    user = User.create! :login => "rtomayko"
    objects = dump(user, email)

    assert_equal 1, objects.size

    dumped = objects[0]
    assert_equal email, dumped.obj
  end

end

class AttributeDumpingTest < ActiveRecordTest

  class User < ActiveRecord::Base
    replicate_enable
  end

  class UserWithLogin < ActiveRecord::Base
    self.table_name = "users"

    replicate_enable
    replicate_attributes :login
  end

  def setup
    super
    User.create! login: "test_user"
  end

  def test_only_id_is_dumped_by_default
    user = User.find_by(login: "test_user")
    objects = dump(user)

    dumped = objects[0]
    assert_equal({"id" => user.id}, dumped.attrs)
  end

  def test_explicity_allowed_attributes
    user = UserWithLogin.find_by(login: "test_user")
    objects = dump(user)

    dumped = objects[0]
    assert_equal({"id" => user.id, "login" => "test_user"}, dumped.attrs)
  end

  def test_dumps_attributes_provided_at_dump_time
    user = User.find_by(login: "test_user")
    objects = dump(user, :attributes => [:login])

    dumped = objects[0]
    assert_equal({"id" => user.id, "login" => "test_user"}, dumped.attrs)
  end

end

class AssociationsDumpingTest < ActiveRecordTest

  class User < ActiveRecord::Base
    has_one  :profile, :dependent => :destroy
    has_many :emails,  -> { order(:id) }, :dependent => :destroy
    has_many :notes,   :as => :notable

    replicate_enable
    replicate_attributes :login
    replicate_associations :profile, :emails, :notes
  end

  class Profile < ActiveRecord::Base
    belongs_to :user

    replicate_enable
    replicate_attributes :user_id, :name
    replicate_associations :user
  end

  class Email < ActiveRecord::Base
    belongs_to :user

    replicate_enable
    replicate_attributes :user_id, :email
    replicate_associations :user
  end

  class Note < ActiveRecord::Base
    belongs_to :notable, :polymorphic => true

    replicate_enable
    replicate_attributes :notable_id, :notable_type
    replicate_associations :notable
  end

  def setup
    super

    user = User.create! :login => "rtomayko"
    user.create_profile :name => "Ryan Tomayko", :homepage => "http://tomayko.com"
    user.emails.create! :email => "ryan@github.com"
    user.emails.create! :email => "rtomayko@gmail.com"
  end

  class UserNoAssoc < ActiveRecord::Base
    self.table_name = "users"

    replicate_enable
    replicate_attributes :login
  end

  def test_ignores_associations_by_default
    user = UserNoAssoc.find_by(login: "rtomayko")
    objects = dump(user)

    assert_equal 1, objects.size, "Dumped more than just the user. #{objects}"
  end

  def test_includes_configured_associations_in_order_with_appropriate_attributes
    user = User.find_by(login: "rtomayko")
    objects = dump(user)

    assert_equal 4, objects.size, "Did not dump enough objects. Found: #{objects.map(&:type)}"

    dumped = objects.shift
    assert_equal user, dumped.obj

    # Has One
    dumped = objects.shift
    assert_equal "AssociationsDumpingTest::Profile", dumped.type
    assert_equal [:id, "AssociationsDumpingTest::User", user.id], dumped.attrs["user_id"]
    assert_equal "Ryan Tomayko", dumped.attrs["name"]
    assert_nil dumped.attrs["homepage"], "Dumped the homepage when it's not configured to dump"

    # Has Many
    dumped = objects.shift
    assert_equal "AssociationsDumpingTest::Email", dumped.type
    assert_equal [:id, "AssociationsDumpingTest::User", user.id], dumped.attrs["user_id"]
    assert_equal "ryan@github.com", dumped.attrs["email"]

    dumped = objects.shift
    assert_equal "AssociationsDumpingTest::Email", dumped.type
    assert_equal [:id, "AssociationsDumpingTest::User", user.id], dumped.attrs["user_id"]
    assert_equal "rtomayko@gmail.com", dumped.attrs["email"]
  end

  def test_belongs_to_added_before_object_being_dumped
    user = User.find_by(login: "rtomayko")
    profile = user.profile
    objects = dump(profile)

    # Belongs To (User)
    dumped = objects.shift
    assert_equal user, dumped.obj

    # Ourself
    dumped = objects.shift
    assert_equal profile, dumped.obj
  end

  class UserWithProfile < ActiveRecord::Base
    self.table_name = "users"

    has_one :profile, :dependent => :destroy, foreign_key: :user_id, class_name: "ProfileFromUser"

    replicate_enable
  end

  class ProfileFromUser < ActiveRecord::Base
    self.table_name = "profiles"
    replicate_enable
  end

  def test_includes_associations_provided_at_dump_time
    user = UserWithProfile.find_by(login: "rtomayko")
    profile = user.profile

    objects = dump(user, :associations => [:profile])

    assert_equal 2, objects.size

    dumped = objects.shift
    assert_equal user, dumped.obj

    dumped = objects.shift
    assert_equal profile, dumped.obj
  end

  def test_dumping_polymorphic_associations
    user = User.find_by(login: "rtomayko")
    note = Note.create! :notable => user
    objects = dump(note)

    dumped = objects.shift
    assert_equal 'AssociationsDumpingTest::User', dumped.type
    assert_equal user, dumped.obj

    dumped = objects.find {|o| o.type == "AssociationsDumpingTest::Note" }
    assert_equal note, dumped.obj
  end

  def test_dumping_empty_polymorphic_association
    note = Note.create!
    objects = dump(note)

    assert_equal 1, objects.size

    dumped = objects.shift
    assert_equal note, dumped.obj
    assert_nil dumped.attrs["notable_id"]
    assert_nil dumped.attrs["notable_type"]
  end

  class User::Namespaced < ActiveRecord::Base
    self.table_name = "namespaced"

    has_many :notes, :source => :notable, :source_type => "Note", :foreign_key => :notable_id

    replicate_enable
    replicate_associations :notes
  end

  def test_dumping_namespaced_polymorphic_associations
    user_namespace = User::Namespaced.create!
    note = Note.create! :notable => user_namespace
    objects = dump(note)
    @dumper.dump note

    assert_equal 2, objects.size

    dumped = objects.shift
    assert_equal 'AssociationsDumpingTest::User::Namespaced', dumped.type
    assert_equal user_namespace, dumped.obj

    dumped = objects.shift
    assert_equal 'AssociationsDumpingTest::Note', dumped.type
    assert_equal note, dumped.obj
  end

end

class HABTMAssociationTest < ActiveRecordTest

  class User < ActiveRecord::Base
    has_and_belongs_to_many :domains, :dependent => :destroy

    replicate_enable
    replicate_attributes :login
    replicate_associations :domains
  end

  class Domain < ActiveRecord::Base
    replicate_enable
    replicate_attributes :host
  end

  def test_dumps_and_loads_habtm_associations
    user = User.create! :login => "test@user.com"
    domain = user.domains.create! :host => "google.com"

    objects = dump(user)

    assert_equal 3, objects.size

    # Ourself
    dumped = objects[0]
    assert_equal user, dumped.obj

    # The Domain
    dumped = objects[1]
    assert_equal domain, dumped.obj

    # The HABTM object
    dumped = objects[2]
    assert_equal "Replicate::AR::Habtm", dumped.type

    User.destroy_all
    Domain.destroy_all

    load(objects)

    user = User.find_by(:login => "test@user.com")
    refute_nil user

    assert_equal 1, user.domains.count
    assert_equal "google.com", user.domains.first.host
  end

end

class LoadingTest < ActiveRecordTest

  class User < ActiveRecord::Base
    has_one  :profile, :dependent => :destroy
    has_many :emails,  -> { order(:id) }, :dependent => :destroy

    replicate_enable
    replicate_natural_key :login
    replicate_attributes :login, :created_at, :updated_at
    replicate_associations :profile, :emails
  end

  class Profile < ActiveRecord::Base
    belongs_to :user

    replicate_enable
    replicate_natural_key :user_id
    replicate_attributes :user_id, :name
    replicate_associations :user
  end

  class Email < ActiveRecord::Base
    belongs_to :user

    replicate_enable
    replicate_natural_key :user_id, :email
    replicate_attributes :user_id, :email
    replicate_associations :user
  end

  class WebPage < ActiveRecord::Base
    belongs_to :domain, :foreign_key => 'domain_host', :primary_key => 'host'

    replicate_enable
    replicate_attributes :url, :domain_host
    replicate_associations :domain
  end

  class Domain < ActiveRecord::Base
    replicate_enable
    replicate_attributes :host
  end

  def setup
    super

    user = User.create! :login => 'rtomayko'
    user.create_profile :name => 'Ryan Tomayko', :homepage => 'http://tomayko.com'
    user.emails.create! :email => 'ryan@github.com'
    user.emails.create! :email => 'rtomayko@gmail.com'

    user = User.create! :login => 'kneath'
    user.create_profile :name => 'Kyle Neath', :homepage => 'http://warpspire.com'
    user.emails.create! :email => 'kyle@github.com'

    user = User.create! :login => 'tmm1'
    user.create_profile :name => 'tmm1', :homepage => 'https://github.com/tmm1'

    github = Domain.create! :host => "github.com"
    WebPage.create! :url => "http://github.com/about", :domain => github
  end

  def test_loading_everything
    dumped_users = {}
    objects = []
    %w[rtomayko kneath tmm1].each do |login|
      user = User.find_by_login(login)
      objects += dump(user)
      user.destroy
      dumped_users[login] = user
    end
    assert_equal 9, objects.size

    # insert another record to ensure id changes for loaded records
    sr = User.create!(:login => 'sr')
    sr.create_profile :name => 'Simon Rozet'
    sr.emails.create :email => 'sr@github.com'

    load(objects)

    # verify attributes are set perfectly again
    user = User.find_by_login('rtomayko')
    assert_equal 'rtomayko', user.login
    assert_equal dumped_users['rtomayko'].created_at, user.created_at
    assert_equal dumped_users['rtomayko'].updated_at, user.updated_at
    assert_equal 'Ryan Tomayko', user.profile.name
    assert_equal 2, user.emails.size

    # make sure everything was recreated
    %w[rtomayko kneath tmm1].each do |login|
      user = User.find_by_login(login)
      refute_nil user
      refute_nil user.profile
      assert !user.emails.empty?, "#{login} has no emails" if login != 'tmm1'
    end
  end

  # This also tests `replicate_natural_key`
  def test_loading_with_existing_records
    objects = []
    dumped_users = {}

    %w[rtomayko kneath tmm1].each do |login|
      user = User.find_by_login(login)
      user.profile.update_attribute :name, 'CHANGED'
      objects += dump(user)
      dumped_users[login] = user
    end
    assert_equal 9, objects.size

    load(objects)

    # ensure additional objects were not created
    assert_equal 3, User.count

    # verify attributes are set perfectly again
    user = User.find_by_login('rtomayko')
    assert_equal 'rtomayko', user.login
    assert_equal dumped_users['rtomayko'].created_at, user.created_at
    assert_equal dumped_users['rtomayko'].updated_at, user.updated_at
    assert_equal 'CHANGED', user.profile.name
    assert_equal 2, user.emails.size

    # make sure everything was recreated
    %w[rtomayko kneath tmm1].each do |login|
      user = User.find_by_login(login)
      refute_nil user
      refute_nil user.profile
      assert_equal 'CHANGED', user.profile.name
      assert !user.emails.empty?, "#{login} has no emails" if login != 'tmm1'
    end
  end

  def test_dumping_and_loading_associations_with_non_standard_keys
    github_about_page = WebPage.find_by_url('http://github.com/about')
    assert_equal "github.com", github_about_page.domain.host
    objects = dump(github_about_page)

    assert_equal 2, objects.size

    WebPage.delete_all
    Domain.delete_all

    load(objects)

    github_about_page = WebPage.find_by_url('http://github.com/about')
    assert_equal "github.com", github_about_page.domain_host
    assert_equal "github.com", github_about_page.domain.host
  end

  class User_TestReplicateId < ActiveRecord::Base
    self.table_name = "users"

    replicate_enable
    replicate_attributes :login
  end

  def test_loading_with_replicating_id
    User_TestReplicateId.replicate_id = false

    objects = []
    dumped_users = {}
    %w[rtomayko kneath tmm1].each do |login|
      user = User_TestReplicateId.find_by_login(login)
      objects += dump(user)
      dumped_users[login] = user
    end
    assert_equal 3, objects.size

    User_TestReplicateId.destroy_all
    User_TestReplicateId.replicate_id = false

    # Load everything to see that ids changed from old to new
    load(objects)

    user = User_TestReplicateId.find_by_login('rtomayko')
    refute_equal dumped_users['rtomayko'].id, user.id

    # Now we turn on replicate_id and see that the ids of the new
    # imported records match what was dumped
    User_TestReplicateId.destroy_all
    User_TestReplicateId.replicate_id = true

    load(objects)

    user = User_TestReplicateId.find_by_login('rtomayko')
    assert_equal dumped_users['rtomayko'].id, user.id
  end

  class User_Validations < ActiveRecord::Base
    self.table_name = "users"

    replicate_enable
    replicate_attributes :login
  end

  def test_loader_saves_without_validations
    # note when a record is saved with validations
    ran_validations = false
    User_Validations.class_eval { validate { ran_validations = true } }

    # check our assumptions
    user = User_Validations.create(:login => 'defunkt')
    assert ran_validations, "should run validations here"
    ran_validations = false

    # load one and verify validations are not run
    user = nil
    @loader.listen { |type, id, attrs, obj| user = obj }
    @loader.feed 'LoadingTest::User_Validations', 1, 'login' => 'rtomayko'
    refute_nil user
    assert !ran_validations, 'validations should not run on save'
  end

  class User_Callbacks < ActiveRecord::Base
    self.table_name = "users"

    replicate_enable
    replicate_attributes :login
  end

  def test_loader_saves_without_callbacks
    # note when a record is saved with callbacks
    callbacks = false
    User_Callbacks.class_eval { after_save { callbacks = true } }
    User_Callbacks.class_eval { after_create { callbacks = true } }
    User_Callbacks.class_eval { after_update { callbacks = true } }
    User_Callbacks.class_eval { after_commit { callbacks = true } }

    # check our assumptions
    user = User_Callbacks.create(:login => 'defunkt')
    assert callbacks, "should run callbacks here"
    callbacks = false

    # load one and verify validations are not run
    user = nil
    @loader.listen { |type, id, attrs, obj| user = obj }
    @loader.feed 'LoadingTest::User_Callbacks', 1, 'login' => 'rtomayko'
    refute_nil user
    assert !callbacks, 'callbacks should not run on save'
  end

  def test_loader_saves_without_updating_created_at_timestamp
    timestamp = Time.at((Time.now - (24 * 60 * 60)).to_i)
    user = nil
    @loader.listen { |type, id, attrs, obj| user = obj }
    @loader.feed 'LoadingTest::User', 23, 'login' => 'brianmario', 'created_at' => timestamp
    assert_equal timestamp, user.created_at
    user = User.find(user.id)
    assert_equal timestamp, user.created_at
  end

  def test_loader_saves_without_updating_updated_at_timestamp
    timestamp = Time.at((Time.now - (24 * 60 * 60)).to_i)
    user = nil
    @loader.listen { |type, id, attrs, obj| user = obj }
    @loader.feed 'LoadingTest::User', 29, 'login' => 'rtomayko', 'updated_at' => timestamp
    assert_equal timestamp, user.updated_at
    user = User.find(user.id)
    assert_equal timestamp, user.updated_at
  end
end
