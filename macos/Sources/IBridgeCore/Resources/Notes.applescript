-- Static, in-process AppleScript. Arguments are AppleEvent descriptors, never source.
-- Notes' public scripting dictionary is the only data source. No database access.
property startedAt : missing value
property visitedFolderIDs : {}
property selectedFolders : {}
property allowedFolderIDs : {}
property folderFilter : ""
property scannedNotes : 0
property returnedCharacters : 0
property didDispatchWrite : false

on checkBudget()
    if ((current date) - startedAt) > 8 then error "Scan deadline" number -2705
end checkBudget

on permitsFolder(folderID)
    considering case
        return (allowedFolderIDs contains "*") or (allowedFolderIDs contains folderID)
    end considering
end permitsFolder

on sameID(firstID, secondID)
    considering case
        return firstID is secondID
    end considering
end sameID

on visitFolders(parentObject)
    my checkBudget()
    tell application id "com.apple.Notes"
        set childCount to count folders of parentObject
        if childCount > 500 then error "Folder limit" number -2704
        repeat with folderIndex from 1 to childCount
            my checkBudget()
            set childFolder to folder folderIndex of parentObject
            set folderID to id of childFolder
            if visitedFolderIDs does not contain folderID then
                set end of visitedFolderIDs to folderID
                if (count visitedFolderIDs) > 500 then error "Folder limit" number -2704
                if (my permitsFolder(folderID)) and (folderFilter is "" or (my sameID(folderFilter, folderID))) then
                    set end of selectedFolders to {folderID, childFolder}
                end if
                my visitFolders(childFolder)
            end if
        end repeat
    end tell
end visitFolders

on boundedText(valueText, maximumSize)
    if (count characters of valueText) > maximumSize then error "Text limit" number -2704
    set returnedCharacters to returnedCharacters + (count characters of valueText)
    if returnedCharacters > 500000 then error "Output limit" number -2704
    return valueText
end boundedText

on noteRecord(selectedNote, folderID, includeBody)
    my checkBudget()
    tell application id "com.apple.Notes"
        -- Verify the actual container before reading any title or body. The caller
        -- only obtains note references from an exactly authorized folder.
        if not (my sameID((id of container of selectedNote), folderID)) then error "Container changed" number -2702
        if password protected of selectedNote then error "Locked note" number -2703
        my checkBudget()
        set noteID to id of selectedNote
        my checkBudget()
        set noteTitle to my boundedText((name of selectedNote), 4096)
        my checkBudget()
        set noteBody to plaintext of selectedNote
        if (count characters of noteBody) > 262144 then error "Text limit" number -2704
        if not includeBody and (count characters of noteBody) > 300 then set noteBody to text 1 thru 300 of noteBody
        set noteBody to my boundedText(noteBody, 262144)
        my checkBudget()
        set hasAttachments to (count attachments of selectedNote) > 0
        my checkBudget()
        if not (my sameID((id of container of selectedNote), folderID)) then error "Container changed" number -2702
        return {noteID, folderID, noteTitle, noteBody, hasAttachments}
    end tell
end noteRecord

on bridge_operation(operationName, permittedIDs, requestedFolder, requestedNote, queryText, htmlBody)
    set startedAt to current date
    set visitedFolderIDs to {}
    set selectedFolders to {}
    set allowedFolderIDs to permittedIDs
    set folderFilter to requestedFolder
    set scannedNotes to 0
    set returnedCharacters to 0
    set didDispatchWrite to false
    try
        if (count permittedIDs) is 0 then error "No permitted folders" number -2701
        if requestedFolder is not "" and not (my permitsFolder(requestedFolder)) then error "Folder not permitted" number -2701
        -- The timeout applies to each AppleEvent. Budget checks bound total
        -- enumeration to eight seconds plus at most one two-second event.
        with timeout of 2 seconds
            tell application id "com.apple.Notes"
                set accountCount to count accounts
                if accountCount > 100 then error "Account limit" number -2704
                repeat with accountIndex from 1 to accountCount
                    my checkBudget()
                    my visitFolders(account accountIndex)
                end repeat
            end tell
            if requestedFolder is not "" and (count selectedFolders) is 0 then error "Folder unavailable" number -2702
            set results to {}
            if operationName is "notes.folders" then
                repeat with entry in selectedFolders
                    my checkBudget()
                    set folderID to item 1 of entry
                    set selectedFolder to item 2 of entry
                    tell application id "com.apple.Notes" to set folderName to name of selectedFolder
                    set end of results to {folderID, my boundedText(folderName, 4096)}
                end repeat
                return {"folders", results}
            end if
            if operationName is "notes.create" then
                if requestedFolder is "" or (count selectedFolders) is not 1 then error "Folder unavailable" number -2702
                set selectedFolder to item 2 of item 1 of selectedFolders
                my checkBudget()
                -- This marker precedes the single mutating AppleEvent. Every error
                -- from here is unknown, even if Notes may have saved successfully.
                set didDispatchWrite to true
                tell application id "com.apple.Notes"
                    set savedNote to make new note at selectedFolder with properties {body:htmlBody}
                    set savedID to id of savedNote
                end tell
                return {"created", savedID}
            end if
            if operationName is not "notes.search" and operationName is not "notes.read" then error "Unknown operation" number -2706
            repeat with entry in selectedFolders
                my checkBudget()
                set folderID to item 1 of entry
                set selectedFolder to item 2 of entry
                tell application id "com.apple.Notes" to set noteCount to count notes of selectedFolder
                set scannedNotes to scannedNotes + noteCount
                if scannedNotes > 2000 then error "Note scan limit" number -2704
                repeat with noteIndex from 1 to noteCount
                    my checkBudget()
                    tell application id "com.apple.Notes"
                        set selectedNote to note noteIndex of selectedFolder
                        set noteID to id of selectedNote
                        -- No global note lookup: a guessed ID cannot bypass folders.
                        my checkBudget()
                        if (my sameID((id of container of selectedNote), folderID)) then
                            if operationName is "notes.read" and (my sameID(noteID, requestedNote)) then
                                return {"read", my noteRecord(selectedNote, folderID, true)}
                            end if
                            if operationName is "notes.search" and not (password protected of selectedNote) then
                                my checkBudget()
                                set noteTitle to name of selectedNote
                                my checkBudget()
                                set noteBody to plaintext of selectedNote
                                if (count characters of noteBody) > 262144 then error "Text limit" number -2704
                                ignoring case
                                    set foundMatch to (noteTitle contains queryText) or (noteBody contains queryText)
                                end ignoring
                                if foundMatch then set end of results to my noteRecord(selectedNote, folderID, false)
                            end if
                        end if
                    end tell
                end repeat
            end repeat
            if operationName is "notes.read" then error "Note unavailable" number -2702
            return {"search", results}
        end timeout
    on error errorMessage number errorNumber
        if didDispatchWrite then return {"error", "unknown"}
        if errorNumber is -2701 then return {"error", "permission_denied"}
        if errorNumber is -2702 then return {"error", "not_found"}
        if errorNumber is -2703 then return {"error", "locked"}
        if errorNumber is -2704 then return {"error", "too_large"}
        if errorNumber is -2705 or errorNumber is -1712 then return {"error", "timeout"}
        -- Native error strings may include personal data. Never return or log them.
        return {"error", "unavailable"}
    end try
end bridge_operation
