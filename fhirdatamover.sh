#!/bin/bash
# some bash magic to trigger an InterSystems IRIS bulk FHIR coordinator export, retrieve the resulting files, and then push them to an AWS bucket, where they can be ingested
# by the InterSystems FHIR to OMOP SaaS offering
# --November 2024, Jost-Philip Matysik (jost-philip.matysik@intersystems.com), InterSystems DACH, all rights reserved



# #################################
# #     Configuration section     #
# #################################


# Define the complete InterSystems IRIS bulk FHIR base URL in URI notation for the instance you want to use (including protocol, port and path).
# The baseurl parameter must not contain a trailing slash!
BulkFHIRbaseurl="http://localhost:33783/bulkFHIR/r4a"
BulkFHIRUser="SuperUser"
BulkFHIRPass="SYS"

# Define the full name of the AWS bucket where we should put the file
myAWSbucket="s3://isc-de-saleseng-jmatysik-projects"
myAWSbucketPath="FHIR2OMOP-Demo/Intake2024-10"





# #################################
# #         Code section          #
# #################################


# go full retro!

# Define colors
BLUE='\033[1;34m'
GREEN='\033[1;32m'
NC='\033[0m' # No Color
echo -e "${BLUE}              "
echo -e "${BLUE}      ${GREEN}|\  ${BLUE}        ___       _            ____            _                      "
echo -e "${BLUE}  |\  ${GREEN}\ \  ${BLUE}      |_ _|_ __ | |_ ___ _ __/ ___| _   _ ___| |_ ___ _ __ ___  ___  "
echo -e "${BLUE}  | |  ${GREEN}| |  ${BLUE}      | || '_ \\| __/ _ \\ '__\\___ \\| | | / __| __/ _ \\ '_ \` _ \\/ __| "
echo -e "${BLUE}  | |  ${GREEN}| |   ${BLUE}     | || | | | ||  __/ |   ___) | |_| \\__ \\ ||  __/ | | | | \\__ \\ "
echo -e "${BLUE}  | |  ${GREEN}| |   ${BLUE}    |___|_| |_|\\__\\___|_|  |____/ \\__, |___/\\__\\___|_| |_| |_|___/ "
echo -e "${BLUE}  | |  ${GREEN}| |   ${BLUE}                                  |___/                            "
echo -e "${BLUE}  \ \   ${GREEN}\|   ${BLUE}    Creative Data Technology"
echo -e "${BLUE}   \|  "
echo -e "${BLUE}    ${NC}"


# Reset color
echo -e "${NC}"


echo -e "\n\nWelcome to the Bulk-FHIR-to-S3-Bucket automation pipeline!"
echo -e "This script was created for DACH Symposium 2024 by Jost-Philip Matysik.\n\n"
echo -e "\e[1;31;47mWarning! This is just a technology demo. NOT FOR PRODUCTION USE!\e[0m"
echo -e "\n\n\nStep 1:"



# initialize variable outside the condition so it exists globally
statusLocation=""


# attempt to trigger the bulk FHIR conversion through the REST interface
#
echo "We are now attempting to trigger a bulk FHIR export on the InterSystems IRIS Bulk FHIR Coordinator"
echo -e "by making a GET request to \e[33m$BulkFHIRbaseurl/\$export\e[0m."
myresponse=$(curl -vs --user SuperUser:SYS $BulkFHIRbaseurl/\$export &> /dev/stdout | grep '< HTTP/1.1\|< CONTENT-LOCATION')

# we are expecting $myresponse to contain two lines. Let's separate them and validate that everything checks out:
IFS=$'\n' read -r -d '' -a lines <<< "$myresponse"
if [[ "${lines[0]:0:23}" == "< HTTP/1.1 202 Accepted" && "${lines[1]:0:20}" == "< CONTENT-LOCATION: " ]]; then

    # extract our Status location from the response header:
    # CAREFUL! The raw string includes the EOL, which we don't want, so we cut off the last character
    statusLocation="${lines[1]:20:-1}"
else
	echo "something went wrong! Server gave unexpected response!"
	exit 444
fi

echo "..."
echo "Triggering the bulk FHIR operation succeeded!"

echo -e "\n\nStep 2:"
echo -e "now repeatedly GETing (just) the headers of $statusLocation to wait for the output to be available..."
statusStatus="HTTP/1.1 202 Accepted"
while [ "$statusStatus" == "HTTP/1.1 202 Accepted" ]; do
    sleep 1
    echo -e "The REST API returned $statusStatus. This means the data is not yet ready! Trying again soon..."
    statusStatus=$(curl -sS -D - --user SuperUser:SYS $statusLocation -o /dev/null | grep "HTTP/1.1")
    # The Status again contains a Newline at the end which we want to get rid of...
    statusStatus=${statusStatus::-1}
done
if [[ "$statusStatus" != "HTTP/1.1 200 OK" ]]; then
    echo -e "ERROR! Server returned unexpected status \"$statusStatus\"!"
    echo -e "We cannot handle that! Abort mission!"
    exit 555
else
    echo -e "\nThe Bulk FHIR Coordinator indicated that the output is now available for download by returning a status of $statusStatus! Happy days!"
fi
    
echo -e "\n\nStep 3:"
echo -e "Now we poll the same REST interface again at $statusLocation, but this time we process the reply body to get the download URLs!"
myURLs=$(curl -s --user SuperUser:SYS $statusLocation | jq | grep "url")

echo -e "Response received. Now extracting the URLs..."


echo -e "\n\nStep 4:"
echo -e "starting URL extraction. Processing response body line by line..."

# Initialize two arrays for all the files and URLs to process. We will need that later on...
myFiles=()
myURLarray=()

# Process each line in the variable
while IFS= read -r line; do

    # Extract the actual URL from each line
    nextURL=$(echo $line | awk '{print $2}')
    # the URLs are enclosed in double quotes. Let's trim them away...
    thisNextURL=${nextURL:1:-1}
    myURLarray+=("$thisNextURL")
   
    # extract just the filename part from the URL (will be passed to curl and zip later on...)
    myFileName="${thisNextURL##*/}"
    
    # create some sane output...
    echo -e "File \"\033[0;32m$myFileName\033[0m\" can be downloaded at URL \"\033[0;33m${myURLarray[-1]}\033[0m\"!"
done <<< "$myURLs"


echo -e "\nProcessing the response done. We extractred ${#myFiles[@]} URLs from the InterSystems Bulk FHIR Coordinator!"

echo -e "\n\nStep5:\nDownload ALL the files!"

echo -e "creating temporary directory in tempfs..."


# Create a folder with a random name in /tmp
folder_name=$(mktemp -d /tmp/tempfs.XXXXXXXX)

# Check if the folder was created successfully
if [[ ! -d "$folder_name" ]]; then
    echo -e "ERROR! Something went wrong while creating the temp directory! Do we have correct permissions on /tmp?"
    exit 666
fi
	
echo -e "Created folder $folder_name"

# change to the directory we just created, and put it onto the directory stack
pushd $folder_name > /dev/null


echo -e "Now downloading this conversion's NDJSON files through the Bulk FHIR Coordinator REST API!"


# download the files!
for downloadURL in "${myURLarray[@]}";do
    curl -s --user SuperUser:SYS -o "${downloadURL##*/}" "$downloadURL"
    status=$?
    if [[ $status -ne 0 ]]; then
        echo "ERROR! The download of \"$downloadURL\" didn't work! Aborting!"
        exit 777
    else
	echo -e "Successfully downloaded \"$downloadURL\"!"
    fi
done


echo -e "\n\nStep 6:\nZip it up!"
myZipFileName=BulkFHIRexport_$(date -u +"%Y-%m-%d-%H.%M.%S").zip 
zip -9 -r $myZipFileName .



echo -e "\n\nStep 7:\nUpload the file to the AWS bucket!"
aws s3 cp "$myZipFileName" "$myAWSbucket/$myAWSbucketPath/"
status=$?
if [[ $status -ne 0 ]]; then
    echo "ERROR! Something went wrong during the upload. Please investigate!\n leaving the temporary files intact..."
    exit 888
else
    echo -e "Successfully uploaded file to S3 bucket!"
fi

echo -e "\n\nStep 8:\nCleaning up!"
echo -e "deleting local temporary files..."
popd > /dev/null
rm -r "$folder_name"


echo -e "\n\nAll Done!\n\n"

exit 0
