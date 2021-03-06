#!/bin/sh
##############################################################################
# Copyright (c) 2013: fritz-hh from Github (https://github.com/fritz-hh)
##############################################################################

TOOLNAME="OCRmyPDF"
VERSION="v1.0-stable"

START=`date +%s`

usage() {
	cat << EOF
--------------------------------------------------------------------------------------
Script aimed at generating a searchable PDF file from a PDF file containing only images.
(The script performs optical character recognition of each respective page using the
tesseract engine)

Copyright: fritz from NAS4Free forum
Version: $VERSION

Usage: OCRmyPDF.sh  [-h] [-v] [-g] [-k] [-d] [-c] [-i] [-l language] [-C filename] inputfile outputfile

-h : Display this help message
-v : Increase the verbosity (this option can be used more than once)
-k : Do not delete the temporary files
-g : Activate debug mode:
     - Generates a PDF file containing each page twice (once with the image, once without the image
       but with the OCRed text as well as the detected bounding boxes)
     - Set the verbosity to the highest possible
     - Do not delete the temporary files
-d : Deskew each page before performing OCR
-c : Clean each page before performing OCR
-i : Incorporate the cleaned image in the final PDF file (by default the original image	
     image, or the deskewed image if the -d option is set, is incorporated)
-l : Set the language of the PDF file in order to improve OCR results (default "eng")
     Any language supported by tesseract is supported.
-C : Pass an additional configuration file to the tesseract OCR engine.
     (this option can be used more than once)
     Note: The configuration file must be available in the "tessdata/configs" folder
     of your tesseract installation
inputfile  : PDF file to be OCRed
outputfile : The PDF/A file to be generated 
--------------------------------------------------------------------------------------
EOF
}


#################################################
# Get an absolute path from a relative path to a file
#
# Param1 : Relative path
# Returns: 1 if the folder in which the file is located does not exist
#          0 otherwise
################################################# 
absolutePath() {
	local wdsave absolutepath 
	wdsave="$(pwd)"
	! cd "$(dirname "$1")" 1> /dev/null 2> /dev/null && return 1
	absolutepath="$(pwd)/$(basename "$1")"
	cd "$wdsave"
	echo "$absolutepath"
	return 0
}



# Initialization of constants
EXIT_BAD_ARGS="1"			# possible exit codes
EXIT_BAD_INPUT_FILE="2"
EXIT_MISSING_DEPENDENCY="3"
EXIT_INVALID_OUPUT_PDFA="4"
EXIT_OTHER_ERROR="5"
LOG_ERR="0"				# 0=only error messages
LOG_INFO="1"				# 1=error messages and some infos
LOG_DEBUG="2"				# 2=debug level logging
SRC="./src"				# location of the source folder (except source of external tools like jhove)
OCR_PAGE="$SRC/ocrPage.sh"		# path to the script aimed at OCRing one page
JHOVE="./jhove/bin/JhoveApp.jar"	# java SW for validating the final PDF/A
JHOVE_CFG="./jhove/conf/jhove.conf"	# location of the jhove config file

# Initialization the configuration parameters with default values
VERBOSITY="$LOG_ERR"		# default verbosity level
LAN="eng"			# default language of the PDF file (required to get good OCR results)
KEEP_TMP="0"			# do not delete the temporary files (default)
PREPROCESS_DESKEW="0"		# 0=no, 1=yes (deskew image)
PREPROCESS_CLEAN="0"		# 0=no, 1=yes (clean image to improve OCR)
PREPROCESS_CLEANTOPDF="0"	# 0=no, 1=yes (put cleaned image in final PDF)
PDF_NOIMG="0"			# 0=no, 1=yes (generates each PDF page twice, with and without image)
TESS_CFG_FILES=""		# list of additional configuration files to be used by tesseract

# Parse optional command line arguments
while getopts ":hvgkdcil:C:" opt; do
	case $opt in
		h) usage ; exit 0 ;;
		v) VERBOSITY=$(($VERBOSITY+1)) ;;
		k) KEEP_TMP="1" ;;
		g) PDF_NOIMG="1"; VERBOSITY="10"; KEEP_TMP="1" ;;
		d) PREPROCESS_DESKEW="1" ;;
		c) PREPROCESS_CLEAN="1" ;;
		i) PREPROCESS_CLEANTOPDF="1" ;;
		l) LAN="$OPTARG" ;;
		C) TESS_CFG_FILES="$OPTARG $TESS_CFG_FILES" ;;
		\?)
			echo "Invalid option: -$OPTARG" >&2
			usage
			exit $EXIT_BAD_ARGS ;;
		:)
			echo "Option -$OPTARG requires an argument" >&2
			usage
			exit $EXIT_BAD_ARGS ;;
	esac
done

# Remove the optional arguments parsed above.
shift $((OPTIND-1))

# Check if the number of mandatory parameters
# provided is as expected
if [ "$#" -ne "2" ]; then
	echo "Exactly two mandatory argument shall be provided ($# arguments provided)" >&2
	usage
	exit $EXIT_BAD_ARGS
fi

! absolutePath "$1" > /dev/null \
	&& echo "The folder in which the input file should be located does not exist. Exiting..." >&2 && exit $EXIT_BAD_ARGS
FILE_INPUT_PDF="`absolutePath "$1"`"
! absolutePath "$2" > /dev/null \
	&& echo "The folder in which the output file should be generated does not exist. Exiting..." >&2 && exit $EXIT_BAD_ARGS
FILE_OUTPUT_PDFA="`absolutePath "$2"`"



# set script path as working directory
cd "`dirname $0`"

[ $VERBOSITY -ge $LOG_INFO ] && echo "$TOOLNAME version: $VERSION"

# check if the required utilities are installed
[ $VERBOSITY -ge $LOG_DEBUG ] && echo "Checking if all dependencies are installed"
! command -v identify > /dev/null && echo "Please install ImageMagick. Exiting..." >&2 && exit $EXIT_MISSING_DEPENDENCY
! command -v parallel > /dev/null && echo "Please install GNU Parallel. Exiting..." >&2 && exit $EXIT_MISSING_DEPENDENCY
! command -v pdfimages > /dev/null && echo "Please install poppler-utils. Exiting..." >&2 && exit $EXIT_MISSING_DEPENDENCY
! command -v pdftoppm > /dev/null && echo "Please install poppler-utils. Exiting..." >&2 && exit $EXIT_MISSING_DEPENDENCY
! command -v pdftk > /dev/null && echo "Please install pdftk. Exiting..." >&2 && exit $EXIT_MISSING_DEPENDENCY
[ $PREPROCESS_CLEAN -eq 1 ] && ! command -v unpaper > /dev/null && echo "Please install unpaper. Exiting..." >&2 && exit $EXIT_MISSING_DEPENDENCY
! command -v tesseract > /dev/null && echo "Please install tesseract and tesseract-data. Exiting..." >&2 && exit $EXIT_MISSING_DEPENDENCY
! command -v python > /dev/null && echo "Please install python, and the python libraries: reportlab, lxml. Exiting..." >&2 && exit $EXIT_MISSING_DEPENDENCY
! command -v gs > /dev/null && echo "Please install ghostcript. Exiting..." >&2 && exit $EXIT_MISSING_DEPENDENCY
! command -v java > /dev/null && echo "Please install java. Exiting..." >&2 && exit $EXIT_MISSING_DEPENDENCY




# Initialize path to temporary files
today=$(date +"%Y%m%d_%H%M")
fld=$(basename "$FILE_INPUT_PDF" | sed 's/[.][^.]*//')
TMP_FLD="./tmp/$today.filename.$fld"
FILE_TMP="$TMP_FLD/tmp.txt"						# temporary file with a very short lifetime (may be used for several things)
FILE_PAGES_INFO="$TMP_FLD/pages-info.txt"				# for each page: page #; width in pt; height in pt
FILE_OUTPUT_PDF_CAT="${TMP_FLD}/ocred.pdf"				# concatenated OCRed PDF files
FILE_OUTPUT_PDFA_WO_META="${TMP_FLD}/ocred-pdfa-wo-metadata.pdf"	# PDFA file before appending metadata
FILE_VALIDATION_LOG="${TMP_FLD}/pdf_validation.log"			# log file containing the results of the validation of the PDF/A file

# Create tmp folder
[ $VERBOSITY -ge $LOG_DEBUG ] && echo "Creating temporary folder: \"$TMP_FLD\""
rm -r -f "${TMP_FLD}"
mkdir -p "${TMP_FLD}"




# get the size of each pdf page (width / height) in pt (inch*72)
[ $VERBOSITY -ge $LOG_DEBUG ] && echo "Input file: Extracting size of each page (in pt)"
! identify -format "%w %h\n" "$FILE_INPUT_PDF" > "$FILE_TMP" \
	&& echo "Could not get size of PDF pages. Exiting..." >&2 && exit $EXIT_BAD_INPUT_FILE
# removing empty lines (last one should be) and prepend page # before each line
sed '/^$/d' "$FILE_TMP" | awk '{printf "%04d %s\n", NR, $0}' > "$FILE_PAGES_INFO"
numpages=`tail -n 1 "$FILE_PAGES_INFO" | cut -f1 -d" "`

# Itterate the pages of the input pdf file
! parallel -k --halt-on-error 1 "$OCR_PAGE" "$FILE_INPUT_PDF" "{}" "$numpages" "$TMP_FLD" \
	"$VERBOSITY" "$LAN" "$KEEP_TMP" "$PREPROCESS_DESKEW" "$PREPROCESS_CLEAN" "$PREPROCESS_CLEANTOPDF" "$PDF_NOIMG" "$TESS_CFG_FILES" < "$FILE_PAGES_INFO" \
	&& exit $?
#while read pageInfo ; do
#	! "$OCR_PAGE" "$FILE_INPUT_PDF" "$pageInfo" "$numpages" "$TMP_FLD" \
#		"$VERBOSITY" "$LAN" "$KEEP_TMP" "$PREPROCESS_DESKEW" "$PREPROCESS_CLEAN" "$PREPROCESS_CLEANTOPDF" "$PDF_NOIMG" "$TESS_CFG_FILES" \
#		&& exit $?
#done < "$FILE_PAGES_INFO"


# concatenate all pages
[ $VERBOSITY -ge $LOG_DEBUG ] && echo "Output file: Concatenating all pages"
! pdftk "${TMP_FLD}/"*-ocred.pdf cat output "$FILE_OUTPUT_PDF_CAT" \
	&& echo "Could not concatenate individual PDF pages (\"${TMP_FLD}/*-ocred.pdf\") to one file. Exiting..." >&2 && exit $EXIT_OTHER_ERROR

# convert the pdf file to match PDF/A format
[ $VERBOSITY -ge $LOG_DEBUG ] && echo "Output file: Converting to PDF/A" 
! gs -dQUIET -dPDFA -dBATCH -dNOPAUSE -dUseCIEColor \
	-sProcessColorModel=DeviceCMYK -sDEVICE=pdfwrite -sPDFACompatibilityPolicy=2 \
	-sOutputFile="$FILE_OUTPUT_PDFA" "$FILE_OUTPUT_PDF_CAT" 1> /dev/null 2> /dev/null \
	&& echo "Could not convert PDF file \"$FILE_OUTPUT_PDF_CAT\" to PDF/A. Exiting..." >&2 && exit $EXIT_OTHER_ERROR

# # Write metadata
# # Needs to be done after converting to PDF/A, as gs does not preserve metadata
# [ $VERBOSITY -ge $LOG_DEBUG ] && echo "Output file: Update metadata (creator, producer, and title)" 
# title=`basename "$FILE_INPUT_PDF" | sed 's/[.][^.]*//' | \
	# sed 's/_/ /g' | sed 's/-/ /g' | \
	# sed 's/\([[:lower:]]\)\([[:upper:]]\)/\1 \2/g' | \
	# sed 's/\([[:alpha:]]\)\([[:digit:]]\)/\1 \2/g' | \
	# sed 's/\([[:digit:]]\)\([[:alpha:]]\)/\1 \2/g'`	# transform the file name (with extension) into distinct words
# pdftk "$FILE_OUTPUT_PDFA_WO_META" update_info_utf8 - output "$FILE_OUTPUT_PDFA" << EOF
# InfoBegin
# InfoKey: Title
# InfoValue: $title
# InfoBegin
# InfoKey: Creator
# InfoValue: $TOOLNAME $VERSION
# InfoBegin
# InfoKey: Producer
# InfoValue: ghostcript `gs --version`, pdftk
# EOF

# validate generated pdf file (compliance to PDF/A)
[ $VERBOSITY -ge $LOG_DEBUG ] && echo "Output file: Checking compliance to PDF/A standard" 
java -jar "$JHOVE" -c "$JHOVE_CFG" -m PDF-hul "$FILE_OUTPUT_PDFA" > "$FILE_VALIDATION_LOG"
grep -i "Status|Message" "$FILE_VALIDATION_LOG" # summary of the validation
[ $VERBOSITY -ge $LOG_DEBUG ] && echo "The full validation log is available here: \"$FILE_VALIDATION_LOG\""
# check the validation results
pdf_valid=1
grep -i 'ErrorMessage' "$FILE_VALIDATION_LOG" >&2 && pdf_valid=0
grep -i 'Status.*not valid' "$FILE_VALIDATION_LOG" >&2 && pdf_valid=0
grep -i 'Status.*Not well-formed' "$FILE_VALIDATION_LOG" >&2 && pdf_valid=0
! grep -i 'Profile:.*PDF/A-1' "$FILE_VALIDATION_LOG" > /dev/null && echo "PDF file profile is not PDF/A-1" >&2 && pdf_valid=0
[ $pdf_valid -ne 1 ] && echo "Output file: The generated PDF/A file is INVALID" >&2
[ $pdf_valid -ne 0 ] && [ $VERBOSITY -ge $LOG_INFO ] && echo "Output file: The generated PDF/A file is VALID"




# delete temporary files
if [ $KEEP_TMP -eq 0 ]; then
	[ $VERBOSITY -ge $LOG_DEBUG ] && echo "Deleting temporary files"
	rm -r -f "${TMP_FLD}"
fi


END=`date +%s`
[ $VERBOSITY -ge $LOG_DEBUG ] && echo "Script took $(($END-$START)) seconds"


[ $pdf_valid -ne 1 ] && exit $EXIT_INVALID_OUPUT_PDFA || exit 0
