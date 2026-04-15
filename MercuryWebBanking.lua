-- MercuryWebBanking.lua
-- MoneyMoney WebBanking-Plugin for Mercury.com transactions
-- Version 1.8.0 - Fixed Treasury balance (was never fetched from API during refresh).
--                 Fixed Credit card balance handling.
--                 Treasury and Credit now fetch live balances from API.
-- Version 1.7.0 - Security & code quality improvements:
--                 Added safeParseJSON helper for readability.
--                 API token format validation.
--                 Token masking in debug output.
--                 Fixed transaction status filter (added 'completed').
--                 Pagination limit warning.
-- Version 1.6.0 - Added support for Credit Card accounts.
-- Known Issue: Treasury account balance may be incorrect due to Mercury API limitations
--              (missing transaction types like dividends/interest).
-- Creation Date: 2025-05-15

-- Define service name as a local constant
local MY_SERVICE_NAME = "Mercury API"
local SCRIPT_VERSION = 1.800 -- Unique internal versioning

-- WebBanking registration call at the very beginning
WebBanking{
    version = 1.0,
    url = "https://mercury.com",
    services = {MY_SERVICE_NAME},
    description = MM.localizeText(MY_SERVICE_NAME)
}

-- Debug switch - set to false for production, true for development
local enableDebug = false -- Set to true for debugging
local function debugLog(message)
    if enableDebug then
        print("[MercuryWebBanking V" .. SCRIPT_VERSION .. " - Service: " .. MY_SERVICE_NAME .. "] " .. message)
    end
end

-- Essential log function for errors or critical info that should always be shown
local function criticalLog(message)
     print("[MercuryWebBanking V" .. SCRIPT_VERSION .. " - CRITICAL - Service: " .. MY_SERVICE_NAME .. "] " .. message)
end

debugLog("Script loading (after WebBanking definition)...")

-- Global variables for the session
local mercuryApiToken = nil
local connection = nil -- MoneyMoney Connection object

-- Helper function to represent tables in logs (only used if enableDebug is true)
local function dump(o)
  if type(o) == 'table' then
    local s = '{ '
    for k, v in pairs(o) do
      if type(k) ~= 'number' then k = '"' .. k .. '"' end
      s = s .. '[' .. k .. '] = ' .. dump(v) .. ','
    end
    if string.len(s) > 2 then s = string.sub(s, 1, -2) end
    return s .. ' } '
  else return tostring(o) end
end

-- Helper function to safely parse JSON with error handling
local function safeParseJSON(content)
    local ok, result = pcall(function() return JSON(content):dictionary() end)
    if ok then
        return result, nil
    else
        return nil, result
    end
end

-- Helper function to mask API token in debug output
local function maskToken(token)
    if not token or #token < 8 then return "***" end
    return string.sub(token, 1, 4) .. "..." .. string.sub(token, -4)
end

-- Helper function to parse date strings (YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS...)
local function parseDate(dateString)
    if not dateString or type(dateString) ~= "string" then
        debugLog("parseDate: Invalid dateString: " .. tostring(dateString))
        return nil
    end
    local datePart = string.match(dateString, "(%d%d%d%d%-%d%d%-%d%d)")
    if not datePart then
        debugLog("parseDate: Could not extract date from string: " .. dateString)
        return nil
    end
    local pattern = "(%d%d%d%d)-(%d%d)-(%d%d)"
    local year, month, day = datePart:match(pattern)
    if year and month and day then
        return os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = 12, min = 0, sec = 0 })
    else
        debugLog("parseDate: Could not parse date (after extraction): " .. datePart)
        return nil
    end
end

-- Helper function to URL-encode query parameters
local function urlEncode(str)
  if (str == nil) then return "" end
  str = string.gsub (str, "\n", "\r\n")
  str = string.gsub (str, "([^%w %-%_%.%~])", function (c) return string.format ("%%%02X", string.byte(c)) end)
  str = string.gsub (str, " ", "+")
  return str
end

-- WebBanking API Functions

function SupportsBank(protocol, bankCode)
    debugLog("SupportsBank: V" .. SCRIPT_VERSION .. " Protocol: " .. tostring(protocol) .. ", BankCode: " .. tostring(bankCode))
    local expectedBankCodeFromServices = MY_SERVICE_NAME
    local result = false
    if type(ProtocolWebBanking) == "nil" then
        criticalLog("SupportsBank: ERROR! Global constant 'ProtocolWebBanking' is nil!")
    else
        if (protocol == ProtocolWebBanking) and (bankCode == expectedBankCodeFromServices) then
            result = true
        end
    end
    debugLog("SupportsBank: Result: " .. tostring(result))
    return result
end

function InitializeSession(protocol, bankCode, username, customer, password)
    debugLog("InitializeSession V" .. SCRIPT_VERSION .. " called...")
    if not password or password == "" then
        criticalLog("InitializeSession: ERROR - No API token in 'Password' field.")
        return "ERROR: Please enter your Mercury API Token into the 'Password' field."
    end
    -- Basic token format validation (Mercury tokens are UUIDs or similar)
    if #password < 20 then
        criticalLog("InitializeSession: ERROR - API token appears too short (" .. #password .. " chars). Expected a valid Mercury API token.")
        return "ERROR: The API token appears invalid (too short). Please check your Mercury API token."
    end
    mercuryApiToken = password
    debugLog("InitializeSession: Mercury API token stored (masked): " .. maskToken(mercuryApiToken))
    connection = Connection()
    if not connection then
        criticalLog("InitializeSession: ERROR - Could not create MoneyMoney Connection object!")
        return "Internal Error: Connection object could not be initialized."
    end
    debugLog("InitializeSession: MoneyMoney Connection object created successfully.")
    return nil
end

function ListAccounts(knownAccounts)
    debugLog("ListAccounts V" .. SCRIPT_VERSION .. " called.")
    if not mercuryApiToken or not connection then return nil, "Session not initialized correctly." end

    local accountsForMoneyMoney = {}
    local headers = { ["Authorization"] = "Bearer " .. mercuryApiToken, ["Accept"] = "application/json" }

    -- 1. Fetch regular accounts
    local regularAccountsApiUrl = "https://api.mercury.com/api/v1/accounts"
    debugLog("ListAccounts: API URL for regular accounts list: " .. regularAccountsApiUrl)
    local regContent = connection:request( "GET", regularAccountsApiUrl, "", "", headers )
    if regContent and regContent ~= "" then
        local regJsonData, regParseError = safeParseJSON(regContent)
        if regJsonData and not regParseError and regJsonData.accounts and type(regJsonData.accounts) == "table" then
            for _, accData in ipairs(regJsonData.accounts) do
                if accData.status == "active" then
                    local accId = accData.id; local accName = accData.nickname or accData.name or ("Account " .. accId)
                    local accCcy = accData.currency or "USD"; local accKind = accData.kind or "checking"
                    local accType = (accKind == "savings" and "AccountTypeSavings" or "AccountTypeChecking")
                    local accBalance = accData.currentBalance; if type(accBalance) ~= "number" then accBalance = accData.availableBalance end; if type(accBalance) ~= "number" then accBalance = nil end
                    table.insert(accountsForMoneyMoney, {name=accName, accountNumber=tostring(accId), currency=accCcy, portfolio=false, type=accType, balance=accBalance, isTreasury=false, isCreditCard=false})
                    debugLog("ListAccounts: Regular Account: Name='" .. accName .. "', ID='" .. accId .. "', Balance=" .. tostring(accBalance))
                end
            end
        else criticalLog("ListAccounts: Error parsing/processing regular accounts. JSON (debug): ".. (enableDebug and dump(regJsonData) or "Debug disabled")) end
    else criticalLog("ListAccounts: ERROR - No response from API (regular accounts).") end

    -- 2. Fetch Treasury accounts
    local treasuryAccountsApiUrl = "https://api.mercury.com/api/v1/treasury"
    debugLog("ListAccounts: API URL for Treasury accounts list: " .. treasuryAccountsApiUrl)
    local tresContent = connection:request( "GET", treasuryAccountsApiUrl, "", "", headers )
    if tresContent and tresContent ~= "" then
        local tresJsonData, tresParseError = safeParseJSON(tresContent)
        if tresJsonData and not tresParseError then
            if tresJsonData.errors then
                 criticalLog("ListAccounts: Treasury API reported errors: " .. (enableDebug and dump(tresJsonData.errors) or "Debug disabled"))
            elseif tresJsonData.accounts and type(tresJsonData.accounts) == "table" then
                for _, accData in ipairs(tresJsonData.accounts) do
                    if accData.status == "active" then
                        local accId = accData.id; local accName = "Treasury"
                        local accCcy = "USD"; local accType = "AccountTypeSavings"
                        local accBalance = accData.currentBalance
                        if type(accBalance) ~= "number" then accBalance = accData.availableBalance end
                        if type(accBalance) ~= "number" then accBalance = nil end
                        table.insert(accountsForMoneyMoney, {name=accName, accountNumber=tostring(accId), currency=accCcy, portfolio=false, type=accType, balance=accBalance, isTreasury=true, isCreditCard=false})
                        debugLog("ListAccounts: Treasury account: Name='" .. accName .. "', ID='" .. accId .. "', Balance=" .. tostring(accBalance))
                    end
                end
            else criticalLog("ListAccounts: 'accounts' array not found in Treasury JSON. JSON (debug): " .. (enableDebug and dump(tresJsonData) or "Debug disabled")) end
        else criticalLog("ListAccounts: ERROR parsing Treasury API response. Error: " .. tostring(tresParseError)) end
    else criticalLog("ListAccounts: NO RESPONSE or empty response from Treasury API endpoint: " .. treasuryAccountsApiUrl) end

    -- 3. Fetch Credit Card accounts
    local creditAccountsApiUrl = "https://api.mercury.com/api/v1/credit"
    debugLog("ListAccounts: API URL for Credit Card accounts list: " .. creditAccountsApiUrl)
    local credContent = connection:request( "GET", creditAccountsApiUrl, "", "", headers )
    if credContent and credContent ~= "" then
        local credJsonData, credParseError = safeParseJSON(credContent)
        if credJsonData and not credParseError and credJsonData.accounts and type(credJsonData.accounts) == "table" then
            for _, accData in ipairs(credJsonData.accounts) do
                if accData.status == "active" then
                    local accId = accData.id
                    -- Use last 4 chars of ID for a somewhat unique name, as card numbers aren't available.
                    local accNameSuffix = string.sub(tostring(accId), -4) 
                    local accName = "Mercury Credit Card " .. accNameSuffix
                    local accCcy = "USD" -- Assuming USD for credit cards, as API doesn't specify currency here.
                    local accType = "AccountTypeCreditCard"
                    local accBalance = accData.currentBalance
                    if type(accBalance) ~= "number" then accBalance = nil end

                    table.insert(accountsForMoneyMoney, {
                        name=accName, 
                        accountNumber=tostring(accId), 
                        currency=accCcy, 
                        portfolio=false, 
                        type=accType, 
                        balance=accBalance, 
                        isTreasury=false, 
                        isCreditCard=true
                    })
                    debugLog("ListAccounts: Credit Card Account: Name='" .. accName .. "', ID='" .. accId .. "', Balance=" .. tostring(accBalance))
                end
            end
        else criticalLog("ListAccounts: Error parsing/processing Credit Card accounts. JSON (debug): ".. (enableDebug and dump(credJsonData) or "Debug disabled") .. (credParseError and (" ParseError: " .. tostring(credParseError)) or "")) end
    else criticalLog("ListAccounts: ERROR - No response from API (Credit Card accounts).") end
    
    debugLog("ListAccounts: Function ending. Account count for MoneyMoney: " .. #accountsForMoneyMoney)
    return accountsForMoneyMoney
end

function RefreshAccount(account, since)
    debugLog("RefreshAccount V" .. SCRIPT_VERSION .. " called for account: " .. account.name .. " (UUID: "..tostring(account.accountNumber).."), Type: " .. tostring(account.type) .. ", since Timestamp: " .. tostring(since))
    
    if not mercuryApiToken or not connection then return nil, "Session not initialized correctly." end
    if not account or not account.accountNumber then return nil, "Error: Invalid account data." end

    local mercuryAccountUUID = account.accountNumber
    local currentBalance = nil 
    local headers = { ["Authorization"] = "Bearer " .. mercuryApiToken, ["Accept"] = "application/json" }
    
    -- Determine account type flags using NAME-based detection
    -- MoneyMoney maps types differently than our internal strings
    -- (e.g., "Credit card" instead of "AccountTypeCreditCard", "Unknown" for Treasury)
    local isTreasuryAccount = string.match(account.name, "^Treasury")
    local isCreditCardAccount = string.match(account.name, "Credit Card")

    debugLog("RefreshAccount: Account '"..account.name.."' flags - isTreasury: " .. tostring(isTreasuryAccount ~= nil) .. ", isCreditCard: " .. tostring(isCreditCardAccount ~= nil) .. ", MM-Type: " .. tostring(account.type))

    if isTreasuryAccount then
        -- Fetch live Treasury balance from API
        debugLog("RefreshAccount: Treasury Account ('" .. account.name .. "'). Fetching live balance from /treasury endpoint.")
        local treasuryApiUrl = "https://api.mercury.com/api/v1/treasury"
        local tresContent = connection:request("GET", treasuryApiUrl, "", "", headers)
        if tresContent and tresContent ~= "" then
            local tresJson, tresErr = safeParseJSON(tresContent)
            if tresJson and not tresErr and tresJson.accounts and type(tresJson.accounts) == "table" then
                local foundTreasury = false
                for _, accData in ipairs(tresJson.accounts) do
                    if tostring(accData.id) == mercuryAccountUUID then
                        currentBalance = accData.currentBalance
                        if type(currentBalance) ~= "number" then currentBalance = accData.availableBalance end
                        if type(currentBalance) ~= "number" then currentBalance = nil end
                        debugLog("RefreshAccount: Treasury balance from API: " .. tostring(currentBalance))
                        foundTreasury = true
                        break
                    end
                end
                if not foundTreasury then
                    -- If specific account not found, sum all active treasury accounts (single Treasury view)
                    local totalBalance = 0
                    local count = 0
                    for _, accData in ipairs(tresJson.accounts) do
                        if accData.status == "active" then
                            local bal = accData.currentBalance or accData.availableBalance or 0
                            if type(bal) == "number" then totalBalance = totalBalance + bal; count = count + 1 end
                        end
                    end
                    if count > 0 then currentBalance = totalBalance end
                    debugLog("RefreshAccount: Treasury ID not found, summed " .. count .. " active accounts: " .. tostring(currentBalance))
                end
            else
                criticalLog("RefreshAccount: Error parsing Treasury API: " .. tostring(tresErr))
                if account.balance ~= nil then currentBalance = account.balance end
            end
        else
            criticalLog("RefreshAccount: No response from Treasury API")
            if account.balance ~= nil then currentBalance = account.balance end
        end
    elseif isCreditCardAccount then
        debugLog("RefreshAccount: Credit Card Account ('" .. account.name .. "'). Fetching balance from /credit endpoint.")
        local creditAccountsApiUrl = "https://api.mercury.com/api/v1/credit"
        local credContent = connection:request("GET", creditAccountsApiUrl, "", "", headers)
        if credContent and credContent ~= "" then
            local credJson, credErr = safeParseJSON(credContent)
            if credJson and not credErr and credJson.accounts and type(credJson.accounts) == "table" then
                local foundAccount = false
                for _, accData in ipairs(credJson.accounts) do
                    if tostring(accData.id) == mercuryAccountUUID then
                        currentBalance = accData.currentBalance
                        if type(currentBalance) ~= "number" then currentBalance = accData.outstandingBalance end
                        if type(currentBalance) ~= "number" then currentBalance = accData.amountDue end
                        if type(currentBalance) ~= "number" then currentBalance = nil end
                        -- Credit card balances are typically negative (money owed)
                        if currentBalance and currentBalance > 0 then currentBalance = -currentBalance end
                        debugLog("RefreshAccount: Balance for Credit Card '"..account.name.."' (ID: "..mercuryAccountUUID..") from API: " .. tostring(currentBalance))
                        foundAccount = true
                        break
                    end
                end
                if not foundAccount then
                    criticalLog("RefreshAccount: Credit Card '"..account.name.."' (ID: "..mercuryAccountUUID..") not found in /credit API response. Using stored balance.")
                    if account.balance ~= nil then currentBalance = account.balance end -- Fallback
                end
            else
                criticalLog("RefreshAccount: Error parsing JSON for Credit Card balance ('"..account.name.."'). Error: " .. tostring(credErr) .. ". Using stored balance.")
                if account.balance ~= nil then currentBalance = account.balance end -- Fallback
            end
        else
            criticalLog("RefreshAccount: ERROR - No response from API (Credit Card balance for '"..account.name.."'). Using stored balance.")
            if account.balance ~= nil then currentBalance = account.balance end -- Fallback
        end
    else
        -- For regular accounts, fetch the balance from /api/v1/account/{UUID}
        local singleAccountApiUrl = "https://api.mercury.com/api/v1/account/" .. mercuryAccountUUID
        debugLog("RefreshAccount: API URL for balance (regular account '".. account.name .."'): " .. singleAccountApiUrl)
        local balanceContent = connection:request("GET", singleAccountApiUrl, "", "", headers)
        if balanceContent and balanceContent ~= "" then
            local bJson, bErr = safeParseJSON(balanceContent)
            if bJson and not bErr then
                if bJson.errors then
                    criticalLog("RefreshAccount: API error fetching single account details for '"..account.name.."': " .. (enableDebug and dump(bJson.errors) or "Debug disabled"))
                    if account.balance ~= nil then currentBalance = account.balance end -- Fallback
                else
                    currentBalance = bJson.currentBalance; if type(currentBalance)~="number" then currentBalance=bJson.availableBalance end; if type(currentBalance)~="number" then currentBalance=nil end
                    debugLog("RefreshAccount: Balance from API (regular account '"..account.name.."'): " .. tostring(currentBalance))
                end
            else
                criticalLog("RefreshAccount: Error parsing JSON (single account '"..account.name.."'): " .. tostring(bErr))
                if account.balance ~= nil then currentBalance = account.balance end -- Fallback
            end
        else
            criticalLog("RefreshAccount: ERROR - No response from API (balance, regular account '"..account.name.."'). Using balance from ListAccounts if available.")
            if account.balance ~= nil then currentBalance = account.balance end -- Fallback
        end
    end
    
    -- Fetch transactions (logic is the same for regular, treasury, and credit accounts as per Mercury docs)
    local allTransactionsForMoneyMoney = {}
    local transactionsApiUrlBase = "https://api.mercury.com/api/v1/account/" .. mercuryAccountUUID .. "/transactions"
    debugLog("RefreshAccount: Fetching transactions for '"..account.name.."' (ID: "..mercuryAccountUUID..") via /account/{id}/transactions.")

    local currentOffset = 0
    local limit = 200 
    local moreTransactionsExist = true
    local totalTransactionsFetchedFromApi = 0
    local pagesFetched = 0
    local queryParams = {}
    local unixEpochStartApprox = 0 

    if not since or since <= unixEpochStartApprox then 
        queryParams.start = "2000-01-01" 
        debugLog("RefreshAccount: 'since' ("..tostring(since)..") for '"..account.name.."' indicates initial fetch. Setting 'start' to " .. queryParams.start)
    else
        local dateSinceTable = os.date("!*t", since); 
        queryParams.start = string.format("%04d-%02d-%02d", dateSinceTable.year, dateSinceTable.month, dateSinceTable.day)
        debugLog("RefreshAccount: Normal fetch for '"..account.name.."'. Filtering transactions with 'start': " .. queryParams.start)
    end
    
    while moreTransactionsExist and pagesFetched < 25 do 
        pagesFetched = pagesFetched + 1
        queryParams.limit = limit
        queryParams.offset = currentOffset

        local queryParamsString = ""
        local firstParam = true
        for key, value in pairs(queryParams) do
            queryParamsString = queryParamsString .. (firstParam and "?" or "&") .. urlEncode(key) .. "=" .. urlEncode(value)
            firstParam = false
        end
        
        local fullApiUrl = transactionsApiUrlBase .. queryParamsString
        debugLog("RefreshAccount: API URL for '"..account.name.."' (Page " .. pagesFetched .. ", Offset " .. currentOffset .. "): " .. fullApiUrl)

        local txContent = connection:request( "GET", fullApiUrl, "", "", headers )
        if not txContent or txContent == "" then
            criticalLog("RefreshAccount: ERROR - No response from API (Transactions, Page " .. pagesFetched .. ") for '"..account.name.."', URL: " .. fullApiUrl)
            moreTransactionsExist = false; break
        end
        
        if enableDebug and #txContent < 2000 then debugLog("RefreshAccount: Response Body (Page " .. pagesFetched .. "): " .. txContent) 
        elseif enableDebug then debugLog("RefreshAccount: Response Body (Page " .. pagesFetched .. ", truncated): " .. string.sub(txContent, 1, 1500)) end

        local txJsonData, tx_ParseError = safeParseJSON(txContent)
        if not txJsonData or tx_ParseError then
            criticalLog("RefreshAccount: ERROR parsing JSON (Transactions, Page " .. pagesFetched .. ") for '"..account.name.."': " .. tostring(tx_ParseError))
            moreTransactionsExist = false; break
        end

        if txJsonData.errors then
            criticalLog("RefreshAccount: API reports errors (Transactions, Page " .. pagesFetched .. ") for '"..account.name.."': " .. (enableDebug and dump(txJsonData.errors) or "Debug disabled"))
            moreTransactionsExist = false; break
        end

        local mercuryAPITransactions = txJsonData.transactions
        if type(mercuryAPITransactions) ~= "table" then
            criticalLog("RefreshAccount: 'transactions' array not found in JSON (Page " .. pagesFetched .. ") for '"..account.name.."'. JSON (debug): " .. (enableDebug and dump(txJsonData) or "Debug disabled"))
            moreTransactionsExist = false; break
        end
        
        local numFetchedThisPage = #mercuryAPITransactions
        totalTransactionsFetchedFromApi = totalTransactionsFetchedFromApi + numFetchedThisPage
        debugLog("RefreshAccount: API Transactions on page " .. pagesFetched .. " for '"..account.name.."': " .. numFetchedThisPage .. ". Total so far: " .. totalTransactionsFetchedFromApi)
        if txJsonData.total then debugLog("RefreshAccount: API reports 'total' transactions for '"..account.name.."': " .. txJsonData.total) end

        if numFetchedThisPage == 0 then 
            moreTransactionsExist = false 
        else
            for _, tx in ipairs(mercuryAPITransactions) do
                local isBooked = tx.postedAt ~= nil
                local isValidStatus = tx.status == "sent" or tx.status == "completed" or (not tx.status and tx.postedAt) 
                if isBooked and isValidStatus then
                    local bDate = tx.createdAt
                    local vDate = tx.postedAt or tx.createdAt
                    local mAmount = tx.amount
                    local mPurpose = tx.note or tx.externalMemo or tx.bankDescription or ""
                    local mCounterparty = tx.counterpartyName or tx.counterpartyNickname or ""
                    local bText = tx.kind or ""
                    local accNum = nil
                    local routeNum = nil

                    if tx.details then
                        local rInfo = tx.details.electronicRoutingInfo or tx.details.domesticWireRoutingInfo or tx.details.internationalWireRoutingInfo
                        if rInfo then
                            accNum = rInfo.accountNumber
                            routeNum = rInfo.routingNumber
                        end
                    end
                    
                    if bDate and mAmount then
                        local bTimestamp = parseDate(bDate)
                        local vTimestamp = parseDate(vDate)
                        if bTimestamp then
                            table.insert(allTransactionsForMoneyMoney, {
                                bookingDate=bTimestamp, valueDate=vTimestamp, amount=tonumber(mAmount), purpose=mPurpose,
                                name=mCounterparty, accountNumber=accNum, bankCode=routeNum, transactionCode=nil, bookingText=bText
                            })
                        end
                    end
                end
            end
            currentOffset = currentOffset + numFetchedThisPage
            if numFetchedThisPage < limit then moreTransactionsExist = false end
            if txJsonData.total and totalTransactionsFetchedFromApi >= txJsonData.total then moreTransactionsExist = false end 
        end
        if moreTransactionsExist then MM.sleep(0.5) end 
    end

    if pagesFetched >= 25 then
        criticalLog("WARNING: Hit pagination limit of 5000 transactions for '"..account.name.."'. Some older transactions may be missing.")
    end
    
    debugLog("RefreshAccount: Pagination for '"..account.name.."' finished. Total API transactions processed: " .. totalTransactionsFetchedFromApi .. ". Formatted for MoneyMoney: " .. #allTransactionsForMoneyMoney)
    
    return {
        transactions = allTransactionsForMoneyMoney,
        balance = currentBalance
    }
end

function EndSession()
    debugLog("EndSession V" .. SCRIPT_VERSION .. " called.")
    mercuryApiToken = nil; connection = nil
    debugLog("EndSession: Session data and connection reset.")
    return nil
end

debugLog("Script V" .. SCRIPT_VERSION .. " fully loaded.")

-- SIGNATURE: MCwCFMercuryAPISignaturePlaceholderAhQMercuryAPISigPlaceV1_70
