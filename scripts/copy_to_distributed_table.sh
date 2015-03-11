#!/bin/sh

# default values for certain options
format='text'
schema='public'

# we'll append to this string to build options list
options='OIDS false, FREEZE false'

# outputs usage message on specified device before exiting with provided status
usage() {
	cat << 'E_O_USAGE' >&"$2"
usage: copy_to_distributed_table [-BCTHh] [-c encoding] [-d delimiter]
	[-e escape] [-n null] [-q quote] [-s schema] filename tablename

  B : use binary format for input
  C : use CSV format for input
  T : use text format for input
  H : specifies file contains header line to be ignored
  h : print this help message

  c : specifies file is encoded using `encoding`
      Default: the current client encoding
  d : specifies the character used to separate columns
      Default: a tab character in text format, a comma in CSV format
  e : specifies the character used to escape quotes
      Default: the same as the `quote` value (quotes within data are doubled)
  n : specifies the string that represents a null value
      Default: \\N in text format, an unquoted empty string in CSV format
  q : specifies the quoting character to be used when a data value is quoted
      Default: double-quote
  s : specifies the schema in which the target table resides
      Default: 'public'
E_O_USAGE

	exit $1;
}

# process flags
while getopts ':BCc:d:e:Hhn:q:T' o; do
	case "${o}" in
		B)
			format='binary'
			;;
		C)
			format='csv'
			;;
		c)
			encoding=`echo ${OPTARG} | sed s/\'/\'\'/g`
			options="${options}, ENCODING '${encoding}'"
			;;
		d)
			delimiter=`echo ${OPTARG} | sed s/\'/\'\'/g`
			options="${options}, DELIMITER '${delimiter}'"
			;;
		e)
			escape=`echo ${OPTARG} | sed s/\'/\'\'/g`
			options="${options}, ESCAPE '${escape}'"
			;;
		H)
			options="${options}, HEADER true"
			;;
		h)
			usage 0 1 # normal status, STDOUT
			;;
		n)
			null=`echo ${OPTARG} | sed s/\'/\'\'/g`
			options="${options}, NULL '${null}'"
			;;
		q)
			quote=`echo ${OPTARG} | sed s/\'/\'\'/g`
			options="${options}, QUOTE '${quote}'"
			;;
		s)
			schema=`echo ${OPTARG} | sed s/\'/\'\'/g`
			;;
		T)
			format='text'
			;;
		*)
			echo "$0: illegal option -- ${OPTARG}" >&2
			usage 64 2 # EX_USAGE, STDERR
			;;
	esac
done
shift $((OPTIND-1))

# append format to options and extract file/table names
options="${options}, FORMAT ${format}"
filename=$1
tablename=$2

# exit if filename or tablename are missing
if [ -z "${filename}" ] || [ -z "${tablename}" ]; then
	echo "$0: filename and tablename are required" >&2
	usage 64 2 # EX_USAGE, STDERR
fi

# TODO: check whether filename exists

# escape single quotes in file/table name and build facade name
filename=`echo ${filename} | sed s/\'/\'\'/g`
facadename=`echo "${tablename}_copy_facade" | sed s/\"/\"\"/g`
tablename=`echo ${tablename} | sed s/\'/\'\'/g`

# invoke psql, ignoring .psqlrc and passing the following heredoc
psql -X << E_O_SQL

-- only print values, left-align them, and don't rollback or stop on error
\set QUIET on
\set ON_ERROR_ROLLBACK off
\pset format unaligned
\pset tuples_only on
\set ON_ERROR_STOP on

-- squelch all output until COPY completes
\o /dev/null

-- Use a session-bound counter to keep track of the number of rows inserted: we
-- can't roll back so we need to tell the user how many rows were inserted. Due
-- to the trigger implementation, the COPY will report zero rows, so we count
-- them manually for a better experience.
CREATE TEMPORARY SEQUENCE rows_inserted MINVALUE 0 CACHE 100000;

-- initialize counter to zero
SELECT nextval('rows_inserted');

-- simple trigger function to tally rows inserted and discard them
CREATE FUNCTION pg_temp.tally_insert() RETURNS trigger AS \$\$
BEGIN
	PERFORM nextval('rows_inserted');
	RETURN NULL;
END; \$\$ LANGUAGE plpgsql;

-- create insert proxy and save name. Use writethrough to enable trigger chain
SELECT create_insert_proxy_for_table('${schema}.${tablename}', true) AS proxy_tablename
\gset

-- install tally trigger; needs to sort alphabetically last
CREATE TRIGGER zzzzz_tally_insert BEFORE INSERT ON pg_temp.:"proxy_tablename"
FOR EACH ROW EXECUTE PROCEDURE pg_temp.tally_insert();

-- don't stop if copy errors out: continue to print file name and row count
\set ON_ERROR_STOP off

\copy pg_temp.${facadename} from ${filename} with ($options)

-- reconnect STDOUT to display row count
\o

SELECT currval('rows_inserted');
E_O_SQL
