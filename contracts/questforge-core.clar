;; questforge-core
;; This smart contract manages the QuestForge Task RPG ecosystem on the Stacks blockchain.
;; It handles user profiles, quest creation/completion, character progression, rewards,
;; achievements, and guild functionality. The contract enables users to transform real-world
;; tasks into quests with blockchain-secured rewards and progression.

;; =========================================
;; Constants & Error Codes
;; =========================================

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-QUEST-NOT-FOUND (err u101))
(define-constant ERR-INVALID-QUEST (err u102))
(define-constant ERR-ALREADY-COMPLETED (err u103))
(define-constant ERR-INSUFFICIENT-FUNDS (err u104))
(define-constant ERR-PROFILE-NOT-FOUND (err u105))
(define-constant ERR-GUILD-NOT-FOUND (err u106))
(define-constant ERR-ALREADY-IN-GUILD (err u107))
(define-constant ERR-NOT-GUILD-MEMBER (err u108))
(define-constant ERR-NOT-GUILD-LEADER (err u109))
(define-constant ERR-INVALID-PARAMS (err u110))
(define-constant ERR-ITEM-NOT-FOUND (err u111))

;; Quest difficulty levels
(define-constant DIFFICULTY-EASY u1)
(define-constant DIFFICULTY-MEDIUM u2)
(define-constant DIFFICULTY-HARD u3)
(define-constant DIFFICULTY-EPIC u4)

;; XP and gold rewards by difficulty
(define-constant XP-REWARD-EASY u50)
(define-constant XP-REWARD-MEDIUM u100)
(define-constant XP-REWARD-HARD u200)
(define-constant XP-REWARD-EPIC u500)

(define-constant GOLD-REWARD-EASY u5)
(define-constant GOLD-REWARD-MEDIUM u15)
(define-constant GOLD-REWARD-HARD u30)
(define-constant GOLD-REWARD-EPIC u75)

;; Achievement IDs
(define-constant ACHIEVEMENT-FIRST-QUEST u1)
(define-constant ACHIEVEMENT-STREAK-WEEK u2)
(define-constant ACHIEVEMENT-LEVEL-10 u3)
(define-constant ACHIEVEMENT-COMPLETE-100 u4)

;; =========================================
;; Data Maps & Variables
;; =========================================

;; Track user profiles with character stats
(define-map user-profiles
  { user: principal }
  {
    level: uint,
    experience: uint,
    gold: uint,
    quests-completed: uint,
    consecutive-days: uint,
    last-quest-date: uint,
    created-at: uint
  }
)

;; Quests data structure
(define-map quests
  { quest-id: uint, owner: principal }
  {
    title: (string-ascii 50),
    description: (string-ascii 200),
    difficulty: uint,
    xp-reward: uint,
    gold-reward: uint,
    is-completed: bool,
    created-at: uint,
    completed-at: uint,
    deadline: (optional uint)
  }
)

;; Track user achievements
(define-map user-achievements
  { user: principal, achievement-id: uint }
  {
    earned-at: uint,
    name: (string-ascii 50),
    description: (string-ascii 200)
  }
)

;; User inventory items
(define-map user-inventory
  { user: principal, item-id: uint }
  {
    name: (string-ascii 50),
    description: (string-ascii 200),
    quantity: uint,
    rarity: uint,
    acquired-at: uint
  }
)

;; Guild information
(define-map guilds
  { guild-id: uint }
  {
    name: (string-ascii 50),
    description: (string-ascii 200),
    leader: principal,
    created-at: uint,
    members-count: uint
  }
)

;; Track guild membership
(define-map guild-members
  { guild-id: uint, member: principal }
  {
    joined-at: uint,
    role: uint
  }
)

;; Counter for quest IDs
(define-data-var next-quest-id uint u1)

;; Counter for guild IDs
(define-data-var next-guild-id uint u1)

;; =========================================
;; Private Functions
;; =========================================

;; Get default user profile
(define-private (default-user-profile)
  {
    level: u1,
    experience: u0,
    gold: u0,
    quests-completed: u0,
    consecutive-days: u0,
    last-quest-date: u0,
    created-at: (unwrap-panic (get-block-info? time u0))
  }
)

;; Check if user has a profile, create one if they don't
(define-private (ensure-user-profile (user principal))
  (match (map-get? user-profiles { user: user })
    profile profile
    (let
      ((new-profile (default-user-profile)))
      (map-set user-profiles { user: user } new-profile)
      new-profile
    )
  )
)

;; Calculate rewards based on quest difficulty
(define-private (calculate-rewards (difficulty uint))
  (let
    (
      (xp-reward
        (cond
          ((is-eq difficulty DIFFICULTY-EASY) XP-REWARD-EASY)
          ((is-eq difficulty DIFFICULTY-MEDIUM) XP-REWARD-MEDIUM)
          ((is-eq difficulty DIFFICULTY-HARD) XP-REWARD-HARD)
          ((is-eq difficulty DIFFICULTY-EPIC) XP-REWARD-EPIC)
          (true u0)
        )
      )
      (gold-reward
        (cond
          ((is-eq difficulty DIFFICULTY-EASY) GOLD-REWARD-EASY)
          ((is-eq difficulty DIFFICULTY-MEDIUM) GOLD-REWARD-MEDIUM)
          ((is-eq difficulty DIFFICULTY-HARD) GOLD-REWARD-HARD)
          ((is-eq difficulty DIFFICULTY-EPIC) GOLD-REWARD-EPIC)
          (true u0)
        )
      )
    )
    { xp-reward: xp-reward, gold-reward: gold-reward }
  )
)

;; Check if leveling up is needed and return new level and experience
(define-private (check-level-up (current-level uint) (new-experience uint))
  (let
    (
      (experience-needed (* current-level u100))
    )
    (if (>= new-experience experience-needed)
      ;; Level up
      {
        level: (+ current-level u1),
        experience: (- new-experience experience-needed),
        did-level-up: true
      }
      ;; No level up
      {
        level: current-level,
        experience: new-experience,
        did-level-up: false
      }
    )
  )
)

;; Check and update streak data
(define-private (update-streak (user principal) (profile (tuple (level uint) (experience uint) (gold uint) (quests-completed uint) (consecutive-days uint) (last-quest-date uint) (created-at uint))))
  (let
    (
      (current-time (unwrap-panic (get-block-info? time u0)))
      (day-seconds u86400)
      (last-date (get last-quest-date profile))
      (days-diff (if (is-eq last-date u0)
                    u0
                    (/ (- current-time last-date) day-seconds)))
    )
    (if (is-eq days-diff u1)
      ;; Consecutive day
      (+ (get consecutive-days profile) u1)
      ;; Streak broken or first quest
      u1
    )
  )
)

;; Check if any achievements were unlocked
(define-private (check-achievements (user principal) (profile (tuple (level uint) (experience uint) (gold uint) (quests-completed uint) (consecutive-days uint) (last-quest-date uint) (created-at uint))))
  (let
    (
      (current-time (unwrap-panic (get-block-info? time u0)))
      (quests-completed (get quests-completed profile))
      (level (get level profile))
      (consecutive-days (get consecutive-days profile))
    )
    
    ;; First quest achievement
    (if (is-eq quests-completed u1)
      (map-set user-achievements
        { user: user, achievement-id: ACHIEVEMENT-FIRST-QUEST }
        {
          earned-at: current-time,
          name: "First Steps",
          description: "Completed your first quest"
        }
      )
      false
    )
    
    ;; Weekly streak achievement
    (if (is-eq consecutive-days u7)
      (map-set user-achievements
        { user: user, achievement-id: ACHIEVEMENT-STREAK-WEEK }
        {
          earned-at: current-time,
          name: "Consistent Adventurer",
          description: "Completed quests for 7 days in a row"
        }
      )
      false
    )
    
    ;; Level 10 achievement
    (if (is-eq level u10)
      (map-set user-achievements
        { user: user, achievement-id: ACHIEVEMENT-LEVEL-10 }
        {
          earned-at: current-time,
          name: "Rising Hero",
          description: "Reached level 10"
        }
      )
      false
    )
    
    ;; 100 quests achievement
    (if (is-eq quests-completed u100)
      (map-set user-achievements
        { user: user, achievement-id: ACHIEVEMENT-COMPLETE-100 }
        {
          earned-at: current-time,
          name: "Centurion",
          description: "Completed 100 quests"
        }
      )
      false
    )
    
    true
  )
)

;; =========================================
;; Read-Only Functions
;; =========================================

;; Get user profile
(define-read-only (get-user-profile (user principal))
  (map-get? user-profiles { user: user })
)

;; Get quest details
(define-read-only (get-quest (quest-id uint) (owner principal))
  (map-get? quests { quest-id: quest-id, owner: owner })
)

;; Get all user quests (returns last 20 quests for pagination simplicity)
(define-read-only (get-user-quests (user principal) (completed bool))
  (let
    (
      (quest-id-max (var-get next-quest-id))
      (start-id (if (< quest-id-max u20) u1 (- quest-id-max u20)))
    )
    (filter filter-quests-by-completion
      (map get-user-quest-by-id
        (fold add-to-id-list
          (list)
          (unwrap-panic (as-max-len?
            (list start-id (+ start-id u1) (+ start-id u2) (+ start-id u3) (+ start-id u4)
                  (+ start-id u5) (+ start-id u6) (+ start-id u7) (+ start-id u8) (+ start-id u9)
                  (+ start-id u10) (+ start-id u11) (+ start-id u12) (+ start-id u13) (+ start-id u14)
                  (+ start-id u15) (+ start-id u16) (+ start-id u17) (+ start-id u18) (+ start-id u19))
            u20
          ))
        )
      )
    )
  )
)

;; Helper for get-user-quests
(define-private (add-to-id-list (id uint) (result (list 20 uint)))
  (unwrap-panic (as-max-len? (append result id) u20))
)

;; Helper for get-user-quests
(define-private (get-user-quest-by-id (id uint))
  (let
    ((quest-data (default-to
      {
        title: "",
        description: "",
        difficulty: u0,
        xp-reward: u0,
        gold-reward: u0,
        is-completed: false,
        created-at: u0,
        completed-at: u0,
        deadline: none
      }
      (map-get? quests { quest-id: id, owner: tx-sender })
    )))
    {
      id: id,
      quest: quest-data
    }
  )
)

;; Helper for get-user-quests to filter by completion status
(define-private (filter-quests-by-completion (quest-data (tuple (id uint) (quest (tuple (title (string-ascii 50)) (description (string-ascii 200)) (difficulty uint) (xp-reward uint) (gold-reward uint) (is-completed bool) (created-at uint) (completed-at uint) (deadline (optional uint)))))))
  (is-eq (get is-completed (get quest quest-data)) completed)
)

;; Get user achievement
(define-read-only (get-user-achievement (user principal) (achievement-id uint))
  (map-get? user-achievements { user: user, achievement-id: achievement-id })
)

;; Get user inventory item
(define-read-only (get-user-item (user principal) (item-id uint))
  (map-get? user-inventory { user: user, item-id: item-id })
)

;; Get guild information
(define-read-only (get-guild (guild-id uint))
  (map-get? guilds { guild-id: guild-id })
)

;; Check if user is in guild
(define-read-only (is-guild-member (guild-id uint) (user principal))
  (is-some (map-get? guild-members { guild-id: guild-id, member: user }))
)

;; =========================================
;; Public Functions
;; =========================================

;; Create a new quest
(define-public (create-quest (title (string-ascii 50)) (description (string-ascii 200)) (difficulty uint) (deadline (optional uint)))
  (let
    (
      (user tx-sender)
      (quest-id (var-get next-quest-id))
      (current-time (unwrap-panic (get-block-info? time u0)))
      (rewards (calculate-rewards difficulty))
      (profile (ensure-user-profile user))
    )
    ;; Validate difficulty level
    (asserts! (and (>= difficulty DIFFICULTY-EASY) (<= difficulty DIFFICULTY-EPIC)) ERR-INVALID-PARAMS)
    
    ;; Create the quest
    (map-set quests
      { quest-id: quest-id, owner: user }
      {
        title: title,
        description: description,
        difficulty: difficulty,
        xp-reward: (get xp-reward rewards),
        gold-reward: (get gold-reward rewards),
        is-completed: false,
        created-at: current-time,
        completed-at: u0,
        deadline: deadline
      }
    )
    
    ;; Increment quest ID
    (var-set next-quest-id (+ quest-id u1))
    
    (ok quest-id)
  )
)

;; Complete a quest
(define-public (complete-quest (quest-id uint))
  (let
    (
      (user tx-sender)
      (current-time (unwrap-panic (get-block-info? time u0)))
      (quest (default-to none (map-get? quests { quest-id: quest-id, owner: user })))
      (profile (ensure-user-profile user))
    )
    ;; Validate quest exists
    (asserts! (is-some quest) ERR-QUEST-NOT-FOUND)
    (asserts! (not (get is-completed (unwrap-panic quest))) ERR-ALREADY-COMPLETED)
    
    (let
      (
        (unwrapped-quest (unwrap-panic quest))
        (xp-reward (get xp-reward unwrapped-quest))
        (gold-reward (get gold-reward unwrapped-quest))
        (new-experience (+ (get experience profile) xp-reward))
        (level-data (check-level-up (get level profile) new-experience))
        (streak (update-streak user profile))
      )
      
      ;; Update quest as completed
      (map-set quests
        { quest-id: quest-id, owner: user }
        (merge unwrapped-quest { is-completed: true, completed-at: current-time })
      )
      
      ;; Update user profile
      (map-set user-profiles
        { user: user }
        {
          level: (get level level-data),
          experience: (get experience level-data),
          gold: (+ (get gold profile) gold-reward),
          quests-completed: (+ (get quests-completed profile) u1),
          consecutive-days: streak,
          last-quest-date: current-time,
          created-at: (get created-at profile)
        }
      )
      
      ;; Check achievements
      (check-achievements user 
        {
          level: (get level level-data),
          experience: (get experience level-data),
          gold: (+ (get gold profile) gold-reward),
          quests-completed: (+ (get quests-completed profile) u1),
          consecutive-days: streak,
          last-quest-date: current-time,
          created-at: (get created-at profile)
        }
      )
      
      (ok { 
        xp-earned: xp-reward, 
        gold-earned: gold-reward, 
        did-level-up: (get did-level-up level-data),
        new-level: (get level level-data)
      })
    )
  )
)

;; Create a new guild
(define-public (create-guild (name (string-ascii 50)) (description (string-ascii 200)))
  (let
    (
      (user tx-sender)
      (guild-id (var-get next-guild-id))
      (current-time (unwrap-panic (get-block-info? time u0)))
    )
    ;; Ensure user has a profile
    (ensure-user-profile user)
    
    ;; Create the guild
    (map-set guilds
      { guild-id: guild-id }
      {
        name: name,
        description: description,
        leader: user,
        created-at: current-time,
        members-count: u1
      }
    )
    
    ;; Add creator as member and leader
    (map-set guild-members
      { guild-id: guild-id, member: user }
      {
        joined-at: current-time,
        role: u1 ;; 1 = leader
      }
    )
    
    ;; Increment guild ID
    (var-set next-guild-id (+ guild-id u1))
    
    (ok guild-id)
  )
)

;; Join a guild
(define-public (join-guild (guild-id uint))
  (let
    (
      (user tx-sender)
      (current-time (unwrap-panic (get-block-info? time u0)))
      (guild (map-get? guilds { guild-id: guild-id }))
    )
    ;; Ensure guild exists
    (asserts! (is-some guild) ERR-GUILD-NOT-FOUND)
    
    ;; Ensure user isn't already in guild
    (asserts! (not (is-guild-member guild-id user)) ERR-ALREADY-IN-GUILD)
    
    ;; Ensure user has a profile
    (ensure-user-profile user)
    
    ;; Add user to guild
    (map-set guild-members
      { guild-id: guild-id, member: user }
      {
        joined-at: current-time,
        role: u0 ;; 0 = regular member
      }
    )
    
    ;; Update member count
    (map-set guilds
      { guild-id: guild-id }
      (merge (unwrap-panic guild)
        { members-count: (+ (get members-count (unwrap-panic guild)) u1) }
      )
    )
    
    (ok true)
  )
)

;; Leave a guild
(define-public (leave-guild (guild-id uint))
  (let
    (
      (user tx-sender)
      (guild (map-get? guilds { guild-id: guild-id }))
      (member-data (map-get? guild-members { guild-id: guild-id, member: user }))
    )
    ;; Validate guild exists
    (asserts! (is-some guild) ERR-GUILD-NOT-FOUND)
    
    ;; Validate user is in guild
    (asserts! (is-some member-data) ERR-NOT-GUILD-MEMBER)
    
    ;; Ensure not leader (leader must transfer leadership first)
    (asserts! (not (is-eq user (get leader (unwrap-panic guild)))) ERR-NOT-AUTHORIZED)
    
    ;; Remove from guild
    (map-delete guild-members { guild-id: guild-id, member: user })
    
    ;; Update member count
    (map-set guilds
      { guild-id: guild-id }
      (merge (unwrap-panic guild)
        { members-count: (- (get members-count (unwrap-panic guild)) u1) }
      )
    )
    
    (ok true)
  )
)

;; Transfer guild leadership
(define-public (transfer-leadership (guild-id uint) (new-leader principal))
  (let
    (
      (user tx-sender)
      (guild (map-get? guilds { guild-id: guild-id }))
      (member-data (map-get? guild-members { guild-id: guild-id, member: new-leader }))
    )
    ;; Validate guild exists
    (asserts! (is-some guild) ERR-GUILD-NOT-FOUND)
    
    ;; Validate current user is leader
    (asserts! (is-eq user (get leader (unwrap-panic guild))) ERR-NOT-GUILD-LEADER)
    
    ;; Validate new leader is in guild
    (asserts! (is-some member-data) ERR-NOT-GUILD-MEMBER)
    
    ;; Update leadership
    (map-set guilds
      { guild-id: guild-id }
      (merge (unwrap-panic guild) { leader: new-leader })
    )
    
    ;; Update roles
    (map-set guild-members
      { guild-id: guild-id, member: user }
      (merge (unwrap-panic member-data) { role: u0 }) ;; Demote current leader
    )
    
    (map-set guild-members
      { guild-id: guild-id, member: new-leader }
      (merge (unwrap-panic member-data) { role: u1 }) ;; Promote new leader
    )
    
    (ok true)
  )
)

;; Add an item to user inventory (admin function for future use)
(define-public (add-inventory-item (user principal) (item-id uint) (name (string-ascii 50)) (description (string-ascii 200)) (quantity uint) (rarity uint))
  (let
    (
      (current-time (unwrap-panic (get-block-info? time u0)))
      (existing-item (map-get? user-inventory { user: user, item-id: item-id }))
    )
    ;; Only contract owner can add items (this would be replaced with proper authorization)
    (asserts! (is-eq tx-sender contract-caller) ERR-NOT-AUTHORIZED)
    
    (if (is-some existing-item)
      ;; Update existing item quantity
      (map-set user-inventory
        { user: user, item-id: item-id }
        (merge (unwrap-panic existing-item)
          { quantity: (+ (get quantity (unwrap-panic existing-item)) quantity) }
        )
      )
      ;; Add new item
      (map-set user-inventory
        { user: user, item-id: item-id }
        {
          name: name,
          description: description,
          quantity: quantity,
          rarity: rarity,
          acquired-at: current-time
        }
      )
    )
    
    (ok true)
  )
)