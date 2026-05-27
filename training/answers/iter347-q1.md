# Answer to Q1: userGroup Selector — What It Matches and How to Configure It (Iter 347)

`userGroup` is **not a group defined inside Trino itself**. It's a list of group names that Trino reads from a separate piece of configuration called a **group provider**.

Your app does NOT pass groups when making the connection. Instead, Trino reads them from a group provider you configure in `etc/group-provider.properties`.

## Where groups come from

There are two main options:
- **File-based** (for static teams): a text file like `etc/groups.txt` where you list `group_name:user1,user2,user3`. When Alice connects, Trino looks up Alice's name in that file and sees which groups she belongs to.
- **LDAP-based** (for larger orgs): Trino queries your LDAP directory to fetch group membership dynamically.

## Multiple groups per user

A single user CAN belong to multiple groups. For example, Alice could be in `["data_engineering", "on_call", "all_employees"]` simultaneously.

The `userGroup` selector matches if **at least ONE** of the user's groups matches the regex. So if Alice has `"data_engineering"` in her groups list, a selector with `"userGroup": "data_engineering"` will match her query — it doesn't matter that she also belongs to other groups.

## What you need to configure

**Step 1: Configure the group provider** in `etc/group-provider.properties`:
```properties
group-provider.name=file
file.group-file=etc/groups.txt
```

**Step 2: Create the groups file** (`etc/groups.txt`):
```
data_engineering:alice,bob,charlie
finance:dave,eve
on_call:alice,frank
```

**Step 3: Use `userGroup` in your resource-groups.json selector:**
```json
{
  "selectors": [
    {
      "userGroup": "data_engineering",
      "group": "global.internal.data_engineering"
    },
    { "group": "global" }
  ]
}
```

## The most common gotcha

If you don't configure a group provider, every user's groups list is empty, and every `userGroup` selector silently fails to match — queries just fall through to the catch-all. You can verify this by checking if `etc/group-provider.properties` exists on your coordinator.

**Resources cited:** `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md`
