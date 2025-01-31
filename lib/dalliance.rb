require 'rails'

require 'state_machine'
require 'benchmark'

require 'dalliance/state_machine'

require 'dalliance/version'
require 'dalliance/workers'
require 'dalliance/progress_meter'

require 'dalliance/engine' if defined?(Rails)

module Dalliance
  extend ActiveSupport::Concern

  class << self
    def options
      @options ||= {
        :background_processing => (defined?(Rails) ? (Rails.env.production? || Rails.env.staging?) : true),
        :dalliance_progress_meter => true,
        :dalliance_progress_meter_total_count_method => :dalliance_progress_meter_total_count,
        :worker_class => detect_worker_class,
        :queue => 'dalliance',
        :logger => detect_logger,
        :duration_column => 'dalliance_duration',
        :error_notifier => ->(e){}
      }
    end

    def background_processing=(value)
      options[:background_processing] = value
    end

    def dalliance_progress_meter=(value)
      options[:dalliance_progress_meter] = value
    end

    def dalliance_progress_meter_total_count_method=(value)
      options[:dalliance_progress_meter_total_count_method] = value
    end

    def worker_class=(value)
      options[:worker_class] = value
    end

    def queue=(value)
      options[:queue] = value
    end

    def logger=(value)
      options[:logger] = value
    end

    def duration_column=(value)
      options[:duration_column] = value
    end

    def error_notifier=(value)
      options[:error_notifier] = value
    end

    def configure
      yield(self) if block_given?
    end

    def detect_worker_class
      return Dalliance::Workers::DelayedJob if defined? ::Delayed::Job
      return Dalliance::Workers::Resque     if defined? ::Resque
    end

    def detect_logger
      if defined?(ActiveRecord)
        ActiveRecord::Base.logger
      elsif defined?(Rails)
        Rails.logger
      else
        ::Logger.new(STDOUT)
      end
    end
  end

  included do
    has_one :dalliance_progress_meter, :as => :dalliance_progress_model, :class_name => '::Dalliance::ProgressMeter', :dependent => :destroy

    serialize :dalliance_error_hash, Hash

    #BEGIN state_machine(s)
    scope :pending, -> { where(:dalliance_status => 'pending') }
    scope :processing, -> { where(:dalliance_status => 'processing') }
    scope :validation_error, -> { where(:dalliance_status => 'validation_error') }
    scope :processing_error, -> { where(:dalliance_status => 'processing_error') }
    scope :completed, -> { where(:dalliance_status => 'completed') }

    state_machine :dalliance_status, :initial => :pending do
      state :pending
      state :processing
      state :validation_error
      state :processing_error
      state :completed

      #event :queue_dalliance do
      #  transition :processing_error => :pending
      #end

      event :start_dalliance do
        transition :pending => :processing
      end

      event :validation_error_dalliance do
        transition :processing => :validation_error
      end

      event :error_dalliance do
        transition all => :processing_error
      end

      event :finish_dalliance do
        transition :processing => :completed
      end
    end
    #END state_machine(s)

    before_destroy :validate_dalliance_status
  end

  module ClassMethods
    def dalliance_status_in_load_select_array
      state_machine(:dalliance_status).states.sort_by(&:name).map {|state| [state.human_name, state.name.to_s] }
    end

    def dalliance_durations
      self.pluck(self.dalliance_options[:duration_column].to_sym)
    end

    def average_duration
      self.average(self.dalliance_options[:duration_column])
    end

    def min_duration
      self.minimum(self.dalliance_options[:duration_column])
    end

    def max_duration
      self.maximum(self.dalliance_options[:duration_column])
    end
  end

  def dalliance_log(message)
    if self.class.dalliance_options[:logger]
      self.class.dalliance_options[:logger].info(message)
    end
  end

  def store_dalliance_validation_error!
    self.dalliance_error_hash = {}

    self.errors.each do |attribute, error|
      self.dalliance_error_hash[attribute] ||= []
      self.dalliance_error_hash[attribute] << error
    end

    begin
      validation_error_dalliance!
    rescue
      begin
        self.dalliance_status = 'validation_error'

        dalliance_log("[dalliance] #{self.class.name}(#{id}) - #{dalliance_status} #{self.dalliance_error_hash}")

        self.dalliance_error_hash = { error: 'Persistance Failure: See Logs' }

        if defined?(Rails) && ::Rails::VERSION::MAJOR > 3
          self.class.where(id: self.id).update_all(dalliance_status: dalliance_status, dalliance_error_hash: dalliance_error_hash )
        else
          self.class.where(id: self.id).update_all(dalliance_status: dalliance_status, dalliance_error_hash: dalliance_error_hash.to_yaml )
        end
      rescue
      end
    end
  end

  def error_notifier
    self.dalliance_options[:error_notifier]
  end

  def error_or_completed?
    validation_error? || processing_error? || completed?
  end

  def validate_dalliance_status
    unless error_or_completed?
      errors.add(:dalliance_status, :invalid)
      if defined?(Rails) && ::Rails::VERSION::MAJOR == 5 && ::Rails::VERSION::MINOR >= 0
        throw(:abort)
      else
        return false
      end
    end

    true
  end

  def pending_or_processing?
    pending? || processing?
  end

  def processing_queue
    if self.class.dalliance_options[:queue].respond_to?(:call)
      self.class.instance_exec self, &dalliance_options[:queue]
    else
      self.class.dalliance_options[:queue]
    end
  end

  #Force backgound_processing w/ true
  def dalliance_background_process(backgound_processing = nil)
    if backgound_processing || (backgound_processing.nil? && self.class.dalliance_options[:background_processing])
      self.class.dalliance_options[:worker_class].enqueue(self, processing_queue)
    else
      dalliance_process(false)
    end
  end

  #backgound_processing == false will re-raise any exceptions
  def dalliance_process(backgound_processing = false)
    start_time = Time.now

    begin
      start_dalliance!

      if self.class.dalliance_options[:dalliance_progress_meter]
        build_dalliance_progress_meter(:total_count => calculate_dalliance_progress_meter_total_count).save!
      end

      self.send(self.class.dalliance_options[:dalliance_method])

      finish_dalliance! unless validation_error?
    rescue StandardError => e
      #Save the error for future analysis...
      self.dalliance_error_hash = {:error => e.class.name, :message => e.message, :backtrace => e.backtrace}

      begin
        error_dalliance!
      rescue
        begin
          self.dalliance_status = 'processing_error'

          dalliance_log("[dalliance] #{self.class.name}(#{id}) - #{dalliance_status} #{dalliance_error_hash}")

          self.dalliance_error_hash = { error: 'Persistance Failure: See Logs' }

          if defined?(Rails) && ::Rails::VERSION::MAJOR > 3
            self.class.where(id: self.id).update_all(dalliance_status: dalliance_status, dalliance_error_hash: dalliance_error_hash )
          else
            self.class.where(id: self.id).update_all(dalliance_status: dalliance_status, dalliance_error_hash: dalliance_error_hash.to_yaml )
          end
        rescue
        end
      end

      error_notifier.call(e)

      #Don't raise the error if we're backgound_processing...
      raise e unless backgound_processing && self.class.dalliance_options[:worker_class].rescue_error?
    ensure
      if self.class.dalliance_options[:dalliance_progress_meter] && dalliance_progress_meter
        #Works with optimistic locking...
        Dalliance::ProgressMeter.delete(dalliance_progress_meter.id)
        self.dalliance_progress_meter = nil
      end

      duration = Time.now - start_time

      dalliance_log("[dalliance] #{self.class.name}(#{id}) - #{dalliance_status} #{duration.to_i}")

      if self.class.dalliance_options[:duration_column]
        self.class.where(id: self.id).update_all(self.class.dalliance_options[:duration_column] => duration.to_i)
      end
    end
  end

  def dalliance_progress
    if completed?
      100
    else
      if self.class.dalliance_options[:dalliance_progress_meter] && dalliance_progress_meter
        dalliance_progress_meter.progress
      else
        0
      end
    end
  end

  #If the progress_meter_total_count_method is not implemented or raises and error just use 1...
  def calculate_dalliance_progress_meter_total_count
    begin
      if respond_to?(self.class.dalliance_options[:dalliance_progress_meter_total_count_method])
        self.send(self.class.dalliance_options[:dalliance_progress_meter_total_count_method])
      else
        1
      end
    rescue
      1
    end
  end

  module Glue
    extend ActiveSupport::Concern

    included do
      class_attribute :dalliance_options
    end

    module ClassMethods
      def dalliance(*args)
        options = args.last.is_a?(Hash) ? Dalliance.options.merge(args.pop) : Dalliance.options

        case args.length
        when 1
          options[:dalliance_method] = args[0]
        else
          raise ArgumentError, "Incorrect number of Arguements provided"
        end

        if dalliance_options.nil?
          self.dalliance_options = {}
        else
          self.dalliance_options = self.dalliance_options.dup
        end

        self.dalliance_options.merge!(options)

        include Dalliance
      end

      def dalliance_options
        self.dalliance_options
      end
    end
  end
end
