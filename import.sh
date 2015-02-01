#!/bin/sh

function die () {
  echo $1
  exit 1
}

function does_database_exist () {
  local output=$(mysql --user=${DATABASE_USER} --password=${DATABASE_PASSWORD} -s -N -e "SELECT schema_name FROM information_schema.schemata WHERE schema_name = '${DATABASE_NAME_NEW}'" information_schema)
  if [[ -z "${output}" ]]; then return 1 ; else return 0 ; fi
}

function database_does_exist () {
  die "Database already exist. Exit to prevent any potential damage."
}

function database_does_not_exist () {
  # Database does not exist; try to create it
  if create_database ; then create_database_success ; else create_database_fail ; fi
}

function create_database () {
  mysql --user=${DATABASE_USER} --password=${DATABASE_PASSWORD} -s -N -e "CREATE DATABASE ${DATABASE_NAME_NEW};"
  if does_database_exist ; then return 0; else return 1; fi  
}

function is_drupal_online () {
  SITE_ONLINE=`drush -d -v core-status --uri=${BASE_URL} --root=${ROOT_DIR} --user=1`
  if [[ $SITE_ONLINE =~ "Connected" ]] && [[ $SITE_ONLINE =~ "Successful" ]] ; then return 0 ; else return 1 ; fi
}

function grant_database_user_appropriate_privileges () {
  local HOST="localhost"
  local output=$(mysql --user=${DATABASE_USER} --password=${DATABASE_PASSWORD} -s -N -e "GRANT CREATE ROUTINE, CREATE VIEW, ALTER, SHOW VIEW, CREATE, ALTER ROUTINE, EVENT, INSERT, SELECT, DELETE, TRIGGER, REFERENCES, UPDATE, DROP, EXECUTE, LOCK TABLES, CREATE TEMPORARY TABLES, INDEX ON ${DATABASE_NAME_NEW}.* TO '${SITE_DATABASE_USER}'@'${HOST}'; REVOKE GRANT OPTION ON ${DATABASE_NAME_NEW}.* FROM '${SITE_DATABASE_USER}'@'${HOST}'; FLUSH PRIVILEGES;")
  if [[ -z "${output}" ]]; then
    return 0 # no error reported
  else
    return 1 # error reported
  fi
}

function import_database () {  
  local output=$(mysql --user=${DATABASE_USER} --password=${DATABASE_PASSWORD} ${DATABASE_NAME_NEW} < ${DATABASE_DUMP})
  if [[ -z "${output}" ]]; then
    return 0 # no error reported
  else
    return 1 # error reported
  fi  
}

# Make sure Drupal is pointing to the correct Apache Solr environment
# Mark to re-index and index all documents
function run_site_apache_solr_environment_tasks ( ) {
  local PING=`curl -s -o /dev/null -w "%{http_code}" ${APACHE_SOLR_URL}/admin/ping`
  # Can we ping Apache Solr Server
  if [ ${PING} == "200" ] 
    then 
      # Step 1
      # Set the correct Apache Solr environment
      SOLR_SET_ENV_URL=$(drush solr-set-env-url ${APACHE_SOLR_URL} --id=solr --uri=${BASE_URL} --root=${ROOT_DIR} --user=1 2>&1 );
      # Test error      
      if [[ $SOLR_SET_ENV_URL == *"error"* ]] ; then return 1 ; else echo "Apache Solr environment step 1 of 3 success"; fi
      # Step 2
      # Mark documents for re-indexing
      SOLR_MARK_DOCUMENTS=$(drush solr-mark-all --environment-id=solr --uri=$BASE_URL --root=$ROOT_DIR --user=1 2>&1 );
      # Test error      
      if [[ $SOLR_MARK_DOCUMENTS == *"error"* ]] ; then return 1 ; else echo "Apache Solr environment step 2 of 3 success"; fi
      # Step 3      
      # Index books
      SOLR_REINDEX_DOCUMENTS=$(drush solr-index --environment-id=solr --uri=$BASE_URL --root=$ROOT_DIR --user=1 2>&1 );
      # Test error
      if [[ $SOLR_REINDEX_DOCUMENTS == *"error"* ]] ; then return 1 ; else echo "Apache Solr environment step 3 of 3 success"; fi
      # No error reported
      return 0    
  else
    echo "Unable to ping Apache Solr environment"
    return 1
  fi
}

function import_fail () {
  echo Import fail
  # remove reference to "corrupted" database
  rm ${SITE_FOLDER}/db.current.txt
  printf ${SITE_CURRENT_DATABASE_NAME} > ${SITE_FOLDER}/db.current.txt
  if is_drupal_online ; then after_import_done_with_fail ; else after_import_done_with_error; fi  
}

function create_database_fail () {
  die "Unable to create database ${DATABASE_NAME_NEW}"
}

function after_import_done_with_fail () {
  die "Site was restored to preview state."
}

function run_site_apache_solr_environment_tasks_fail () {
  echo "Unable to run all Apache Solr tasks."
  import_fail
}

function grant_database_user_appropriate_privileges_fail () {
  die "Unable to grant privileges to ${SITE_DATABASE_USER} database ${DATABASE_NAME_NEW}."
}

function import_success () {
  DATABASE_STRING_MATHCHED=$(grep "'database' => '${SITE_CURRENT_DATABASE_NAME}'," ${SITE_SETTINGS} >&1)
  if ! test -z  "${DATABASE_STRING_MATHCHED}" ; then
    # copy the file
    cp ${SITE_SETTINGS} ${SITE_FOLDER}/${SITE_CURRENT_DATABASE_NAME}.settings.php
    # read from the new database
    perl -pi -e "s/$SITE_CURRENT_DATABASE_NAME/$DATABASE_NAME_NEW/g" ${SITE_SETTINGS}  
    echo "/** ${DATE}: ${WHOAMI} : Import bash script changed database string ${SITE_CURRENT_DATABASE_NAME} to ${DATABASE_NAME_NEW} */" >> ${SITE_SETTINGS}
    echo "/** ${DATE}: ${WHOAMI} : ${COMMENT} */" >> ${SITE_SETTINGS}    
  else
    import_fail
  fi
  # Clean Drupal cache
  drush cc all --uri=${BASE_URL} --root=${ROOT_DIR} --user=1 
  # Make sure the site still online after the import
  if is_drupal_online ; then after_import_done_with_success ; else import_fail; fi
}

function after_import_done_with_success () {
  echo "Import success."
}

function create_database_success () {
  echo "Successfully created database ${DATABASE_NAME_NEW}"
}

function run_site_apache_solr_environment_tasks_success {
  echo "Apache Solr tasks ran without error."
  after_import_done_with_success
}

function grant_database_user_appropriate_privileges_success () {
  echo "Successfully granted privileges to ${SITE_DATABASE_USER} for database ${DATABASE_NAME_NEW}."
}

function after_import_done_with_error () {
  die "Error. Unable to restore site to online state."
}

NOW=`date +%s`

DATE=`date`

WHOAMI=`whoami`

ENVIRONMENT=local

DATABASE_NAME_NEW=books_"$ENVIRONMENT"_"$NOW"

while getopts ":d:r:u:s:a:c:h" opt; do
  case $opt in
    d)
      [ -f $OPTARG ] || die "SQL dump not available" 
      DATABASE_DUMP=$OPTARG
      ;;
    r)
      [ -f $OPTARG/index.php ] || die "Drupal root directory does not exist." 
      ROOT_DIR=$OPTARG
      ;;
    u)
      DATABASE_USER=$OPTARG
      ;;  
    s)
      BASE_URL=$OPTARG
      ;;    
    a)
      APACHE_SOLR_URL=$OPTARG
      ;;
    c)
      COMMENT=$OPTARG
      ;;           
    h)
      echo " "
      echo " Usage: ./import.sh -s http://localhost:8000/books -r /www/sites/books -d /Users/ortiz/dump.sql -u admin -a http://localhost:8080/solr -c 'Reference to JIRA ticket'"
      echo " "
      echo " Options:"
      echo "   -d <file>         Specify the SQL dump to use for the import."
      echo "   -r <directory>    Specify Drupal root directory."
      echo "   -u <string>       Specify mysql username (user must have right to create databases and assign privileges)."
      echo "   -s <uri>          Specify site URI."
      echo "   -a <uri>          Specify Apache Solr URI."      
      echo "   -c <string>       Ideally a reference to the ticket for this import."
      echo "   -h                Show brief help"
      echo " "  
      exit 0
      ;;
    esac
done

# Check if we have a database dump
[ $DATABASE_DUMP ] || die "No database dump available."

# Check if we have a admin database user
[ $DATABASE_USER ] || die "No mysql admin user."

# Check if we have the Apache Solr URI
[ $APACHE_SOLR_URL ] || die "No Apache Solr URI available."

# Test if ROOT_DIR directory looks like a Drupal 7 installation folder.
[ ! `grep -q 'DRUPAL_ROOT' $ROOT_DIR/index.php` ] || die "$ROOT_DIR does not look like a Drupal installation folder."

# Make sure the current site is online; if online continue
if is_drupal_online ; then echo "Site online."; else die "Site offline."; fi

# Find the database user the site use to connect to mysql
SITE_DATABASE_USER=`drush sql-connect --uri=${BASE_URL} --root=${ROOT_DIR} --user=1 | awk '{print $4}' | sed "s/--user=//g"`

# Make sure we found the user
[ $SITE_DATABASE_USER ] || die "Unable to find the database user that this site use to connect to mysql."

# Make sure we do not use the same user to run ops and the site
[ ${DATABASE_USER} != ${SITE_DATABASE_USER} ] || die "URGENT: MySQL admin (${DATABASE_USER}) user should not be the same as the MySQL the site use (${SITE_DATABASE_USER}).";

SITE_CURRENT_DATABASE_NAME=`drush sql-connect --uri=${BASE_URL} --root=${ROOT_DIR} --user=1 | awk '{print $2}' | sed "s/--database=//g"`

# Make sure we found the current database name
[ $SITE_CURRENT_DATABASE_NAME ] || die "Unable to find the current database that this site use."

SITE_FOLDER=${ROOT_DIR}/sites/default

# Exit if user does not have rights to write to site folder
[ -w $SITE_FOLDER ] || die "Unable to write to ${SITE_FOLDER}"

SITE_SETTINGS=${ROOT_DIR}/sites/default/settings.php

# Exit if user does not have rights to read to site settings
[ -r $SITE_SETTINGS ] || die "Unable to read ${SITE_SETTINGS}"

# Exit if user does not have rights to write to site settings
[ -w $SITE_SETTINGS ] || die "Unable to write to ${SITE_SETTINGS}"

# Read mysql user password from tty. This is the user with privilege to run ops,
# not the user the Drupal site use.
read -s -p "Enter Password for mysql user $DATABASE_USER: " DATABASE_PASSWORD

# New line
echo 

# Check if the database exist; exit if exist, otherwise create it.
# We want to fail this test and run `database_does_not_exist`
# - This check might be useless because we use UNIX timestamp
if does_database_exist ; then database_does_exist ; else database_does_not_exist ; fi

# We have a database and admin user can connect. Assign appropriate privileges
# to the site database user
if grant_database_user_appropriate_privileges ; then grant_database_user_appropriate_privileges_success ; else grant_database_user_appropriate_privileges_fail ; fi

# Import the SQL dump into the newly created database
if import_database ; then import_success ; else import_fail ; fi

# Make sure the site is pointing to the correct Apache Solr and index the site content
if run_site_apache_solr_environment_tasks ; then run_site_apache_solr_environment_tasks_success ; else run_site_apache_solr_environment_tasks_fail ; fi

exit 0
