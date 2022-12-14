#!/usr/bin/env python

from jupyter_server.auth import passwd

if __name__ == "__main__":
    print("Generate a access token")
    from argparse import ArgumentParser
    parser = ArgumentParser()
    parser.add_argument("-p",
        "--password", 
        dest="password",
        help="The password you want to use for authentication.",
        required=True)
    args = parser.parse_args()

    print("\nCopy this line into the .env file:\n")
    hash = passwd(args.password)
    print(f"ACCESS_TOKEN='{hash}'")
