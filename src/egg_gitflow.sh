#!/bin/bash

set -e

git clone $GIT_SRC
cd $GIT_NAME

if [ ! -z "$GIT_CHANGE_ID" ]; then
        GIT_BRANCH=PR-${GIT_CHANGE_ID}
        git fetch origin pull/$GIT_CHANGE_ID/head:$GIT_BRANCH
        files_changed=$(git --no-pager diff --name-only $GIT_BRANCH $(git merge-base $GIT_BRANCH master))

        if [ $(echo $files_changed | grep $GIT_HISTORYFILE | wc -l) -eq 0 ]; then
             echo "Pipeline aborted due to no history file changed"
             exit 1
        fi
        echo "Passed check: History file updated"

        if [ $(echo $files_changed | grep $GIT_VERSIONFILE | wc -l) -eq 0 ]; then
             echo "Pipeline aborted due to no version file changed"
             exit 1
        fi
        echo "Passed check: Version file updated"

        git checkout $GIT_BRANCH
        version=$(printf '%s' $(cat $GIT_VERSIONFILE))
        echo "Version is $version"

        if [ $(git tag | grep -c "^$version$" ) -ne 0 ]; then
         echo "Pipeline aborted due to version already present in tags"
         exit 1
        fi
        echo "Passed check: Version is not present in git tags"

        if [[ ! $version  =~ ^[0-9]+\.[0-9]+$ ]] ; then
         echo "Version ${version} does not respect format: \"number.number\", please change it"
         exit 1
        fi
        echo "Passed check: Version format is number.number"


        git fetch --tags
        if [ $(git tag | wc -l) -eq 0 ]; then
             echo "Passed check: New version is bigger than last released version (no versions released yet)"
        else
                latestTag=$(git describe --tags `git rev-list --tags --max-count=1`)
                check_version_bigger=$(echo $version"."$latestTag | awk -F. '{if ($1 > $3 || ( $1 == $3 && $2 > $4) ) print "OK"}')

                if [[ ! $check_version_bigger == "OK" ]]; then
                 echo "Pipeline aborted due to version ${version} being smaller than last version ${last_version}"
                 exit 1
                fi
                echo "Passed check: New version is bigger than last released version"
        fi
        echo "Passed all checks"
fi


if [[ "$GIT_BRANCH" == "master" ]]; then

        #check if release already exists
        version=$(printf '%s' $(cat $GIT_VERSIONFILE))
        echo "--------------------------------------------------------------------------------------------------------------------"
 
        echo "Preparing .pypirc file for release"
        export HOME=$(pwd)
        mv /pypirc.template .pypirc
        
        echo "Checking if version is released on EGGREPO"
        egg_releases=$(curl -s -i "${EGGREPO_URL}d/${GIT_NAME}/")

        
        if [ $(echo "$egg_releases" | grep -Ec "(HTTP/1.1 200)|(HTTP/1.1 404)") -ne 1 ]; then 
           echo "There was a problem with the EGG repository - HTTP response code not 200 or 404"
           echo "Please check ${EGGREPO_URL}d/${GIT_NAME}/"
           echo "$egg_releases"
           exit 1
        fi

        if [ $(echo "$egg_releases" | grep -c "HTTP/1.1 404") -eq 1 ] || [ $(echo "$egg_releases" | grep -c ">${GIT_NAME}-${version}.zip<") -ne 1 ]; then
            echo "Starting the release ${GIT_NAME}-${version}.zip on EEA repo"
            sed -i "s#EGGREPO_URL#${EGGREPO_URL}#g" .pypirc
            sed -i "s#EGGREPO_USERNAME#${EGGREPO_USERNAME}#g" .pypirc
            sed -i "s#EGGREPO_PASSWORD#${EGGREPO_PASSWORD}#g" .pypirc
            mkrelease -CT -d eea .
            echo "Release ${GIT_NAME}-${version}.zip done on ${EGGREPO_URL}"
        
       else
           echo "Release ${GIT_NAME}-${version}.zip already exists on EEA repo, skipping"
        fi

        echo "--------------------------------------------------------------------------------------------------------------------"

        echo "Checking if version is released on PyPi"
    
        pypi_releases=$(curl -i -s "${PYPI_CHECK_URL}${GIT_NAME}/")
        

        if [ $(echo "$pypi_releases" | grep -Ec "(HTTP/1.1 200)|(HTTP/1.1 404)") -ne 1 ]; then
           echo "There was a problem with the PIPY repository - HTTP response code not 200 or 404"
           echo "Please check ${PYPI_CHECK_URL}${GIT_NAME}/"
           echo "$pypi_releases"
           exit 1
        fi

        if [ $(echo "$pypi_releases" | grep -c "HTTP/1.1 404") -eq 1 ]; then 
          echo "Egg will not be released on PyPi because it does not have any releases - ${PYPI_CHECK_URL}${GIT_NAME}/"
        else   
          
          if [ $(echo "$pypi_releases" | grep -c ">${GIT_NAME}-${version}.zip<") -ne 1 ]; then
             echo "Starting the release ${GIT_NAME}-${version}.zip on PyPi repo"
             sed -i "s#PYPI_USERNAME#${PYPI_USERNAME}#g" .pypirc
             sed -i "s#PYPI_PASSWORD#${PYPI_PASSWORD}#g" .pypirc
             mkrelease -CT -d pypi .
             echo "Release ${GIT_NAME}-${version}.zip  done on PyPi"
          else
            echo "Release ${GIT_NAME}-${version}.zip already exists on PyPi repo, skipping"
          fi
        fi
        echo "--------------------------------------------------------------------------------------------------------------------"

        #check if tag exiss
        if [ $(git tag | grep -c "^$version$") -eq 0 ]; then
         echo "Starting the creation of the tag $version on master"

         curl_result=$(curl -i -s -X POST -H "Authorization: bearer $GIT_TOKEN" --data "{\"tag_name\": \"$version\", \"target_commitish\": \"master\", \"name\": \"$version\", \"body\":  \"Release $version\", \"draft\": false, \"prerelease\": false }"   https://api.github.com/repos/${GIT_ORG}/${GIT_NAME}/releases )
        
         if [ $( echo $curl_result | grep -c  "HTTP/1.1 201" ) -eq 0 ]; then
            echo "There was a problem with the release"
            echo $curl_result
            exit 1
         fi

         echo "Release $version succesfully created"

        else
          echo "Tag $version already created, skipping"
        fi

        echo "--------------------------------------------------------------------------------------------------------------------"
      # Updating versions.cfg
     echo "Starting the update of KGS versions.cfg"
     curl -s -X GET  -H "Authorization: bearer $GIT_TOKEN"  -H "Accept: application/vnd.github.VERSION.raw" "https://api.github.com/repos/${GIT_ORG}/${KGS_GITNAME}/contents/${KGS_VERSIONS_PATH}"  > versions.cfg

     if [ $(grep -c "\[versions\]" versions.cfg) -eq 0 ]; then
       echo "There was a problem getting the versions file"
       cat versions.cfg
       exit 1
     fi

     if [ $(grep -c "^${GIT_NAME} = $version$" versions.cfg) -eq 1 ]; then
         echo "KGS versions file already updated, skipping"
     else
       old_version=$( grep  "^${GIT_NAME} =" versions.cfg | awk '{print $3}')

       check_version_bigger=$(echo $version"."$old_version | awk -F. '{if ($1 > $3 || ( $1 == $3 && $2 > $4) ) print "OK"}')

       if [[ ! $check_version_bigger == "OK" ]]; then
         echo "${version} is smaller than the version from ${KGS_GITNAME} - ${old_version}, skipping"
       else

         echo "Updating KGS versions file with released version"

         curl_result=$( curl -s -X GET  -H "Authorization: bearer $GIT_TOKEN" "https://api.github.com/repos/${GIT_ORG}/${KGS_GITNAME}/contents/${KGS_VERSIONS_PATH}" )

         if [ $( echo $curl_result | grep -c '"sha"' ) -eq 0 ]; then
            echo "There was a problem with the GitHub API request:"
            echo $curl_result
            exit 1
         fi


         sha_versionfile=$(echo $curl_result |  python -c "import sys, json; print json.load(sys.stdin)['sha']")

         grep -q "^${GIT_NAME} =" versions.cfg  && sed -i "s/^${GIT_NAME} =.*/${GIT_NAME} = $version/" versions.cfg || sed -i "/# automatically set /a ${GIT_NAME} = $version" versions.cfg

         result=$(curl -i -s -X PUT -H "Authorization: bearer $GIT_TOKEN" --data "{\"message\": \"Release ${GIT_NAME} $version\", \"sha\": \"${sha_versionfile}\", \"committer\": { \"name\": \"${GIT_USERNAME}\", \"email\": \"${GIT_EMAIL}\" }, \"content\": \"$(printf '%s' $(cat versions.cfg | base64))\"}" "https://api.github.com/repos/${GIT_ORG}/${KGS_GITNAME}/contents/${KGS_VERSIONS_PATH}")

         if [ $(echo $result | grep -c "HTTP/1.1 200") -eq 1 ]; then
            echo "KGS versions file updated succesfully"
         else
            echo "There was an error updating the KGS file, please check the execution"
            echo $result
            exit 1
         fi
      fi
 fi

fi


exec "$@"

