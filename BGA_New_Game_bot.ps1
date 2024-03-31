# Script to scrape the beta forums of BGA, then gather and post about new releases on discord
# Andrew Lund
# 3-31-24
# 1.0

Clear-Variable matches, PHPSESSIDcookie, XRequestToken, response, getCookieSession, session, listOfBetaForumPosts, betaForumResponse, collectedNewGames -ErrorAction SilentlyContinue
$oldProgressPreference = $progressPreference
$progressPreference = 'SilentlyContinue'

$workingDir = "C:\Scripts\BGA_Announce_Bot\"
$logFileName = "BGA_Announce.txt"
$logPathFull = "$workingDir\$logFileName"
$logFileContents = Get-Content $logPathFull
if ((Test-Path -LiteralPath "$workingDir") -eq $false) { mkdir "$workingDir" }
if ((Test-Path -LiteralPath "$workingDir\$logFileName") -eq $false) { Out-File "$workingDir\$logFileName" }

# full url of discord webhook should be in secrets.txt
$discordWebHook = cat "$workingDir\secrets.txt"

$collectedNewGames = @() # initialize array

class BGABetaForumPost {
    $BGAGameName
    $gamePanelGameName # spellbook - https://boardgamearena.com/gamepanel?game=spellbook
    $linktoForumPost # https://en.boardgamearena.com/forum/viewtopic.php?t=35747
    $postTitle # SpellBook is now in béta
    $BGALinkToGame # gamepanel link e.g. https://boardgamearena.com/gamepanel?game=spellbook
    $BGGID # 391834 in https://boardgamegeek.com/boardgame/391834/spellbook
    $BGGURL # https://boardgamegeek.com/boardgame/391834/spellbook
    $forumPostID # 35747 - unique key identifier
    $gamePictureURL
}


[regex]$xRequestTokenRegex = "requestToken:.*?\'(.*)\'"
[regex]$ogImageRegex = 'og\:image.*?="(.*)"\/>' # https://en.boardgamearena.com/gamepanel?game=arknova
[regex]$topicIDRegex = '.*?t\=(\d+?)\&' # ./viewtopic.php?t=15783&amp;sid=721cca6bc8f36acc124bb066cf4f4003

$uriBase = "https://en.boardgamearena.com/"
$gamePlayPageURIBase = "$($uriBase)gamepanel?game" # https://en.boardgamearena.com/gamepanel?game

# Function: getCookies
# Input: None
# Output: Returns PHPSessionCookie string, and xreqtoken string
function getCookies {
    $phpSessionCookie = ((Invoke-WebRequest -uri "$($uriBase)").BaseResponse.Cookies | Where-Object { $_.Name -eq 'PHPSESSID' }).Value
    $getCookieSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $getCookieSession.Cookies.Add((New-Object System.Net.Cookie("PHPSESSID", "$($phpSessionCookie)", "/", "en.boardgamearena.com")))

    $xreqToken = (Invoke-WebRequest -UseBasicParsing `
            -Uri "$($gamePlayPageURIBase)=arknova" `
            -WebSession $getCookieSession).content -match $xRequestTokenRegex | ForEach-Object { $Matches[1] }

    return($phpSessionCookie, $xreqToken)
}

# Function: createAndSendGameDetailCall
# Input: phpSessCookie: Passed in from "getCookies" function
# Input: xRequestToken: Passed in from "getCookies" function
# Input: gameName: name of game from uri e.g. arknova - https://en.boardgamearena.com/gamepanel?game=arknova
# Output: Returns full xml object with game details
function createAndSendGameDetailCall {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $phpSessCookie,
        [Parameter()]
        [string]
        $xRequestToken,
        [Parameter()]
        [string]
        $gameName
    )
    Clear-Variable session, response -ErrorAction SilentlyContinue

    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $session.Cookies.Add((New-Object System.Net.Cookie("PHPSESSID", "$($phpSessCookie)", "/", "en.boardgamearena.com")))
    $response = Invoke-RestMethod -UseBasicParsing -Uri "$($uriBase)gamelist/gamelist/gameDetails.html" `
        -Method POST `
        -WebSession $session `
        -Headers @{
        "X-Request-Token" = "$($xRequestToken)"
    } `
        -ContentType "application/x-www-form-urlencoded;charset=UTF-8" `
        -Body "game=$($gameName)"
    return($($response.results))
}

# Function: checkForNewForumPosts
# Input: None
# Output: Returns Object/array of new posts from the beta forum - https://forum.boardgamearena.com/viewforum.php?f=243
function checkForNewForumPosts {
    # Grab list of current forum posts in BETA thread, then filter to ones that are new and ones that are not stickied
    $betaForumResponse = (Invoke-WebRequest -uri "https://forum.boardgamearena.com/viewforum.php?f=243&lang=en").links
    $listOfBetaForumPosts = ($betaForumResponse | Where-Object { $_.class -eq 'topictitle' })[0..10]
    foreach ($betaPost in $listOfBetaForumPosts) {
        Clear-Variable Matches, forumtopicID -ErrorAction SilentlyContinue
        $forumTopicID = $betaPost.href -match $topicIDRegex | ForEach-Object { $matches[1] }
        $betaPost | Add-Member -MemberType NoteProperty "ForumTopicID" -Value "$($forumTopicID)" 
    }

    $newBetaForumPosts = $listOfBetaForumPosts | Where-Object { $logFileContents -notcontains $_.ForumTopicID } # Filter out ones we've already reported
    return($newBetaForumPosts)
}


# Function: createAndSendCardDiscord
# Input: collected game object ($collectedNewGames)
# Output: None
function createAndSendCardDiscord {
    param($collectedGames)

    foreach ($game in $collectedGames) {
        Clear-Variable jsonbody, embeds -ErrorAction SilentlyContinue
        # Generate the body hashtable and conver to JSON to send to webhook
        $jsonBody = @{
            embeds     = @(
                @{
                    title      = "$($game.BGAGameName) on BGA"
                    url        = "$($game.BGALinkToGame)"
                    color      = 5898646
                    avatar_url = "https://x.boardgamearena.net/data/themereleases/240320-1000/img/logo/waiting.gif"
                    fields     = @(
                        @{
                            name   = "BGG link"
                            value  = "$($game.BGGURL)"
                            inline = $true
                        },
                        @{
                            name  = "$([Text.Encoding]::ASCII.GetString([Text.Encoding]::GetEncoding("Cyrillic").GetBytes($([System.Web.HttpUtility]::HtmlDecode($game.postTitle)))))"
                            value = "$($game.linktoForumPost)"
                        }
                    )
                    thumbnail  = @{
                        url = "$($game.gamePictureURL)"
                    }
                }
            )
            username   = "BGA Release Bot"
            avatar_url = "https://x.boardgamearena.net/data/themereleases/240320-1000/img/logo/waiting.gif"
        } | ConvertTo-Json -Depth 100

        Foreach ($webhook in $discordWebHook) {
            Try {
                Invoke-RestMethod -uri $($webhook) -Body $jsonBody -Method Post -ContentType "application/json"
                # Then save the forumpostid so that it isn't reported again
                $game.forumPostID | Out-File -LiteralPath "$logPathFull" -Append    
        
            }
            Catch {
                Write-host "Error with" $_.Exception.Message       
                Write-host "JSONBODY:"
                Write-host $jsonBody
            }
        }
    }
}

$PHPSESSIDcookie, $XRequestToken = getCookies
$newPostsFound = checkForNewForumPosts

# Is there a new post to report on?
if ($newPostsFound.count -gt 0) {
    foreach ($newPost in $newPostsFound) {
        Clear-Variable matches, pictureURI, gamepanelname, gameData, gamePanelDataXML -ErrorAction SilentlyContinue
        Try {
            $firstGamePanelURLFound = ((Invoke-WebRequest -uri "https://forum.boardgamearena.com/viewtopic.php?t=$($newPost.ForumTopicID)").links | Where-Object { $_.href -like "*gamepanel*" })[0]

            $gamePanelName = $($firstGamePanelURLFound.href -match "game=(.+?)($|\&)" | ForEach-Object { $matches[1] })
            $gamePanelDataXML = createAndSendGameDetailCall -phpSessCookie $PHPSESSIDcookie -xRequestToken $XRequestToken -gameName $($gamePanelName)
            $pictureURI = (Invoke-RestMethod -uri "$gamePlayPageURIBase=$gamePanelName") -match $ogImageRegex | ForEach-Object { $matches[1] }


            $gameData = [BGABetaForumPost]::new()

            $gameData.BGAGameName = "$($gamePanelDataXML.game_name)"
            $gameData.gamePanelGameName = "$gamePanelName"
            $gameData.BGGID = "$($gamePanelDataXML.bgg_id)"
            $gameData.forumPostID = "$($newPost.ForumTopicID)"
            $gameData.postTitle = "$($newPost.outerText)"
            $gameData.BGALinkToGame = "$gamePlayPageURIBase=$gamePanelName"
            $gameData.linktoForumPost = "https://forum.boardgamearena.com/viewtopic.php?t=$($newPost.ForumTopicID.toString())"
            $gameData.BGGURL = "https://boardgamegeek.com/boardgame/$($gamePanelDataXML.bgg_id.toString())"
            $gameData.gamePictureURL = "$pictureURI"

            $collectedNewGames += $gameData
        }
        catch {
            Write-Host "Error with" $_.Exception.Message 
        }
    }

    createAndSendCardDiscord -collectedGames $collectedNewGames

} # End of new posts found IF
$progressPreference = $oldProgressPreference