module Citier
  module Base

    def self.included(base)
      base.send :extend, RequiredMethods
    end

    module RequiredMethods

      def acts_as_citier(options = {})
        self.new.class.send :extend, ClassMethods

        # Option for setting the inheritance columns, default value = 'type'
        db_type_field = (options[:db_type_field] || :type).to_s

        #:table_name = option for setting the name of the current class table_name, default value = 'tableized(current class name)'
        table_name = (options[:table_name] || self.name.tableize.gsub(/\//,'_')).to_s

        self.inheritance_column = "#{db_type_field}"

        if(self.superclass!=ActiveRecord::Base)
          # Non root-class

          citier_debug("Non Root Class")
          citier_debug("table_name -> #{table_name}")

          # Set up the table which contains ALL attributes we want for this class
          self.table_name = "view_#{table_name}"

          citier_debug("tablename (view) -> #{self.table_name}")

          # The the Writable. References the write-able table for the class because
          # save operations etc can't take place on the views
          self.const_set("Writable", create_class_writable(self))

          after_initialize do
            self.id = nil if self.new_record? && self.id == 0
          end

          # Add the functions required for children only
          send :include, Citier::ChildInstanceMethods
        else
          # Root class

          citier_debug("Root Class")

          self.table_name = "#{table_name}"

          citier_debug("table_name -> #{self.table_name}")

          # Add the functions required for root classes only
          send :include, Citier::RootInstanceMethods
        end
      end

      def acts_as_citier?
        false
      end
    end

    module ClassMethods
      def self.extended(base)
        base.send :include, InstanceMethods
      end

      def acts_as_citier?
        true
      end

      def [](column_name) 
        arel_table[column_name]
      end

      def create_class_writable(class_reference)
        Class.new(ActiveRecord::Base) do
          include Citier::ForcedWriters

          # set the name of the writable table associated with the class_reference class
          self.table_name = get_writable_table(class_reference.table_name)
        end
      end

      # Strips 'view_' from the table name if it exists
      def get_writable_table(table_name)
        if table_name[0..4] == "view_"
          return table_name[5..table_name.length]
        end
        return table_name
      end
    end

    module InstanceMethods
      def is_new_record(state)
        @new_record = state
      end

      def create_citier_view(theclass)
        # function for creating views for migrations 
        # flush any column info in memory
        # Loops through and stops once we've cleaned up to our root class.
        # We MUST user Writable as that is the place where changes might reside!
        reset_class = theclass::Writable 
        until reset_class == ActiveRecord::Base
          citier_debug("Resetting column information on #{reset_class}")
          reset_class.reset_column_information
          reset_class = reset_class.superclass
        end

        self_columns = theclass::Writable.column_names.select{ |c| c != "id" }
        parent_columns = theclass.superclass.column_names.select{ |c| c != "id" }
        columns = parent_columns+self_columns
        self_read_table = theclass.table_name
        self_write_table = theclass::Writable.table_name
        parent_read_table = theclass.superclass.table_name
        sql = "CREATE VIEW #{self_read_table} AS SELECT #{parent_read_table}.id, #{columns.join(',')} FROM #{parent_read_table}, #{self_write_table} WHERE #{parent_read_table}.id = #{self_write_table}.id" 

        #Use our rails_sql_views gem to create the view so we get it outputted to schema
        create_view "#{self_read_table}", "SELECT #{parent_read_table}.id, #{columns.join(',')} FROM #{parent_read_table}, #{self_write_table} WHERE #{parent_read_table}.id = #{self_write_table}.id" do |v|
          v.column :id
          columns.each do |c|
            v.column c.to_sym
          end
        end

        citier_debug("Creating citier view -> #{sql}")
      end

      def drop_citier_view(theclass) #function for dropping views for migrations 
        self_read_table = theclass.table_name
        sql = "DROP VIEW #{self_read_table}"

        drop_view(self_read_table.to_sym) #drop using our rails sql views gem

        citier_debug("Dropping citier view -> #{sql}")
        #theclass.connection.execute sql
      end

      def update_citier_view(theclass) #function for updating views for migrations
        citier_debug("Updating citier view for #{theclass}")
        if theclass.table_exists?
          drop_citier_view(theclass)
          create_citier_view(theclass)
        else
          citier_debug("Error: #{theclass} VIEW doesn't exist.")
        end
      end

      def create_or_update_citier_view(theclass) #Convienience function for updating or creating views for migrations
        citier_debug("Create or Update citier view for #{theclass}")

        if theclass.table_exists?
          update_citier_view(theclass)
        else
          citier_debug("VIEW DIDN'T EXIST. Now creating for #{theclass}")
          create_citier_view(theclass)
        end
      end
    end
  end
end

ActiveRecord::Base.send :include, Citier::Base