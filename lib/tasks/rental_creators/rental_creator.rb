require './lib/tasks/import_formatter'

module RentalCreator

  # Supports rental or sales
  DEFAULT_TRANSACTION_TYPE = "rental"

  def get_source_from_job job_id
    source = ImportJob.where( id: job_id ).pluck(:source).first
  end

  def create_import_log(row)

    if discard? row
      puts "\t\tdiscarding record for: " + row["origin_url"]
      return nil
    end

    puts "\t\tcreating new import_log: " + row["origin_url"]
    import_log = ImportLog.create
    import_log[:address]          = row["address"]
    import_log[:neighborhood]     = row["neighborhood"]
    import_log[:bedrooms]         = ImportFormatter.to_float row["bedrooms"]
    import_log[:bathrooms]        = ImportFormatter.to_float row["bathrooms"]
    import_log[:price]            = ImportFormatter.to_float row["price"]
    import_log[:sqft]             = ImportFormatter.to_float row["sqft"]
    import_log[:garage]           = row["garage"]
    import_log[:year_built]       = row["year_built"]
    import_log[:date_closed]      = ImportFormatter.to_date row["date_closed"]
    import_log[:date_listed]      = ImportFormatter.to_date row["date_listed"]
    import_log[:date_transacted]  = import_log[:date_closed] || import_log[:date_listed]
    import_log[:source]           = row["source"]
    import_log[:origin_url]       = row["origin_url"]
    import_log[:import_job_id]    = row["import_job_id"]
    import_log[:transaction_type] = row["transaction_type"] || DEFAULT_TRANSACTION_TYPE
    import_log[:sfh]              = is_single_family? row
    import_log.save!
    import_log
  end

  def discard? row
    if ImportFormatter.to_float(row["sqft"]) == 0
      puts "\t\tsqft is 0"
      return true       
    elsif ImportFormatter.to_float(row["price"]) == 0
      puts "\t\tprice is 0"
      return true 
    elsif row["address"].include? "Undisclosed Address"
      puts "\t\taddress is undisclosed"
      return true 
    elsif ![*0..9].map { |n| n.to_s}.include? row["address"][0]
      puts "\t\taddress does not have street number"
      return true 
    else
      return false      
    end

  end

  # To be overwritten: Determines if record corresponds to a single family home
  #
  # Params: 
  #   CSV::ROW
  #
  # Returns:
  #   Boolean
  #
  def is_single_family?( csv_row )
    false
  end

  def generate_import_diffs( curr_import_job_id )
    puts "\nProcessing import_diffs"
    generate_created_and_modified_diffs curr_import_job_id 
    generate_deleted_diffs curr_import_job_id 
  end

  def generate_created_and_modified_diffs( curr_import_job_id )
    puts "\n\tProcessing created, updated import_diffs"
    previous_import_job_id = self.get_previous_batch_id curr_import_job_id 

    added_rows = 0
    modified_rows = 0

    # There was no previous batch ever imported
    if previous_import_job_id.nil? == true
      get_sorted_import_logs( curr_import_job_id ).each_with_index do |import_log, index|
        puts "\n\t\tRow. #{index}: processing import log #{import_log.id}"
        self.create_import_diff( curr_import_job_id, import_log, "created", import_log[:id] )
        added_rows += 1
      end

    # There was a previous batch
    else

      get_sorted_import_logs( curr_import_job_id ).each_with_index do |import_log, index|
        puts "\n\t\tRow. #{index}: processing import log #{import_log.id}"
        # There was a previous batch ever imported
        previous_log = self.get_matching_import_log_from_batch import_log, previous_import_job_id

        if previous_log.nil?
          added_rows += 1
          puts "\t\tcould not find "+ import_log[:origin_url] +" in Job: " + previous_import_job_id.to_s
          self.create_import_diff( curr_import_job_id, import_log, "created", import_log[:id], nil )

        elsif self.is_changed? previous_log, import_log
          modified_rows += 1
          puts "\t\tchange detected for "+ import_log[:origin_url] +" in Job: " + curr_import_job_id.to_s
          self.create_import_diff( curr_import_job_id, import_log, "updated", import_log[:id], previous_log[:id] )

        else
          puts "\t\tno change detected for "+ import_log[:origin_url] +" in Job: " + curr_import_job_id.to_s

        end

      end
    end
    ImportJob.where(id: curr_import_job_id).update_all(added_rows: added_rows)
    ImportJob.where(id: curr_import_job_id).update_all(modified_rows: modified_rows)
  end

  # To Be Completed
  def generate_deleted_diffs( curr_import_job_id )
    puts "\n\tProcessing deleted import_diffs"
    previous_import_job_id = self.get_previous_batch_id curr_import_job_id

    
    if previous_import_job_id.nil?
      ImportJob.where(id: curr_import_job_id).update_all(removed_rows: 0)
      return
    end
    removed_rows = 0
    get_sorted_import_logs( previous_import_job_id ).each_with_index do |prev_log, index|
      puts "\n\t\tRow. #{index}: detecting for changes to log #{prev_log.id} from batch #{previous_import_job_id}"
      current_log = self.get_matching_import_log_from_batch prev_log, curr_import_job_id
      if current_log.nil?
        removed_rows += 1
        puts "\t\tcorresponding log does not exist in current batch #{curr_import_job_id}"
        temp_log = prev_log.dup
        temp_log[:date_listed] = nil
        temp_log[:date_closed] = Time.now
        self.create_import_diff( curr_import_job_id, temp_log, "deleted", nil, prev_log[:id] )
      else
        puts "\t\tcorresponding log exist in current batch #{curr_import_job_id}"
      end

    end
    ImportJob.where(id: curr_import_job_id).update_all(removed_rows: removed_rows)

  end

  # Returns the import_logs belonging to an import job in ascending order
  def get_sorted_import_logs previous_import_job_id
    ImportLog.where( import_job_id: previous_import_job_id ).order( date_transacted: :asc)
  end

  def get_previous_batch_id job_id
    curr_job = ImportJob.where( id: job_id ).first
    curr_job.get_previous_job_id
  end

  # Creates a new import_diff entry
  #
  # Params:
  #   import_log: ImportLog
  #   diff_type:String
  #     - created
  #     - updated
  #     - deleted
  #
  def create_import_diff(curr_job_id, import_log, diff_type, new_log_id, old_log_id=nil)
    import_diff = get_import_diff curr_job_id, import_log

    if import_diff.nil?
      puts "\t\trecord was #{diff_type} : " + import_log[:origin_url]
      import_diff = ImportDiff.create
      import_diff[:address]           = import_log[:address]
      import_diff[:neighborhood]      = import_log[:neighborhood]
      import_diff[:bedrooms]          = import_log[:bedrooms]
      import_diff[:bathrooms]         = import_log[:bathrooms]
      import_diff[:price]             = import_log[:price]
      import_diff[:sqft]              = import_log[:sqft]
      import_diff[:garage]            = import_log[:garage]
      import_diff[:year_built]        = import_log[:year_built]
      import_diff[:level]             = import_log[:level]
      import_diff[:date_closed]       = import_log[:date_closed]
      import_diff[:date_listed]       = import_log[:date_listed]
      import_diff[:date_transacted]   = import_log[:date_transacted]
      import_diff[:source]            = import_log[:source]
      import_diff[:origin_url]        = import_log[:origin_url]
      import_diff[:import_job_id]     = curr_job_id
      import_diff[:transaction_type]  = import_log[:transaction_type]
      import_diff[:sfh]               = import_log[:sfh]
      import_diff[:diff_type]         = diff_type
      import_diff[:old_log_id]        = old_log_id
      import_diff[:new_log_id]        = new_log_id
      import_diff.save!
      import_diff        
    end
  end

  def set_normalcy!( job_id )
    curr_job = ImportJob.find job_id
    curr_job.set_normalcy!
  end

  def generate_properties job_id
    curr_job = ImportJob.find job_id

    if curr_job.is_abnormal?
      raise "Property generation not allowed because ImportJob (ID: #{job_id}) was abnormal"
    end

    puts "\nProcessing properties for job #{job_id}"
    processed_count = 0
    ImportDiff.where( import_job_id: job_id ).each do |import_diff|
      processed_count += 1
      puts "\n\tProcessing import diff No.#{processed_count}"
      create_property import_diff
    end
    LuxuryAddress.set_property_grades    

  end

  def create_property import_diff

    property = get_matching_property import_diff[:origin_url]
    if property.nil?
      puts "\n\tNew property detected: #{import_diff[:origin_url]}\n\tSource: #{import_diff[:source]}"
      property = Property.create!(
        address:        import_diff[:address],
        neighborhood:   import_diff[:neighborhood],
        bedrooms:       import_diff[:bedrooms],
        bathrooms:      import_diff[:bathrooms],
        sqft:           import_diff[:sqft],
        year_built:     import_diff[:year_built],
        garage:         import_diff[:garage],
        source:         import_diff[:source],
        origin_url:     import_diff[:origin_url],
        level:          import_diff[:level],
        sfh:            import_diff[:sfh]
      )
    else
      puts "\n\tUpdating property: #{import_diff[:origin_url]}\n\tSource: #{import_diff[:source]}"
      property.address      = import_diff[:address]
      property.neighborhood = import_diff[:neighborhood]
      property.bedrooms     = import_diff[:bedrooms]
      property.bathrooms    = import_diff[:bathrooms]
      property.sqft         = import_diff[:sqft]
      property.year_built   = import_diff[:year_built]
      property.garage       = import_diff[:garage]
      property.level        = import_diff[:level]
      property.sfh          = import_diff[:sfh]
      property.save!
    end

  end

  def generate_transactions job_id
    curr_job = ImportJob.where( id: job_id ).first
    if curr_job.is_abnormal?
      raise "Property Transactions not allowed because ImportJob (ID: #{job_id}) was abnormal"
    end

    puts "\nProcessing transactions for job #{job_id}"
    source = get_source_from_job job_id
    processed_count = 0
    ImportDiff.where( import_job_id: job_id ).each do |import_diff|
      processed_count += 1
      puts "\tRecord No.#{processed_count}: Generating new transaction: #{import_diff[:origin_url]}\n\tSource: #{import_diff[:source]}"
      create_transaction import_diff
    end
  end

  # Method to be overwritten
  # Creates the transaction
  def create_transaction import_diff
    transaction_type = import_diff["transaction_type"] || DEFAULT_TRANSACTION_TYPE
    property = get_matching_property import_diff[:origin_url]
    transaction = PropertyTransactionLog.guess property[:id], import_diff[:date_closed], import_diff[:date_listed], transaction_type

    date_listed = nil
    if import_diff[:date_closed].nil?
      date_listed = import_diff[:date_listed] || get_default_date_listed
    end

    # This transaction was never priorly captured
    if transaction.nil?
      PropertyTransactionLog.create!(
        property_id: property[:id],
        price: import_diff[:price],
        date_listed: date_listed,
        date_closed: import_diff[:date_closed],
        transaction_type: transaction_type
      )

    # This transaction was priorly captured
    else
      transaction.date_closed = import_diff[:date_closed] unless import_diff[:date_closed].nil?
      transaction.date_listed = date_listed unless date_listed.nil?
      transaction.save!
    end
  end  

  # Method to be overwritten
  # Returns the default date_listed value for creating a property transaction record if value is not available
  def get_default_date_listed
    nil
  end  

  # Method to be overwritten
  # Returns the matching transaction record
  def get_matching_transaction import_diff
    # PropertyTransactionLog.where(:)
  end

  # Method to be overwritten
  # Returns the matching property record
  def get_matching_property property_url
    Property.where( origin_url: property_url ).first
  end

  # Method to be overwritten
  # Returns the matching record from the previous batch
  def get_matching_import_log_from_batch import_log, job_id
    ImportLog.where( 
      origin_url: import_log[:origin_url], 
      import_job_id: job_id,
      source: import_log[:source]
    ).first      
  end

  # Method to be overwritten
  # Returns true if current record has changed as compared to same record in previous batch
  def is_changed? old_log, new_log
    false
  end

  # Method to be overwritten
  # Gets the corresponding import_diff given an import log
  def get_import_diff curr_job_id, import_log
    import_diff = ImportDiff.where( 
      import_job_id: curr_job_id,
      origin_url: import_log[:origin_url],       
      source: import_log[:source]
    ).first    
  end

end